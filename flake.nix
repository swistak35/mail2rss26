{
  description = "mail2rss26 — newsletters arriving by mail, served as Atom feeds";

  inputs = {
    # The same channel Rivendell pins: this flake ends up as one of its inputs,
    # and two nixpkgs revisions in one closure is a cost with no benefit.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs =
    { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;

      # One server and one workstation, both x86_64-linux. Another platform is one
      # more string here, not a refactor.
      systems = [ "x86_64-linux" ];

      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Which interpreter the gems, the tests and the package are built against.
      # Named once so they cannot drift apart.
      rubyFor = pkgs: pkgs.ruby;

      # The single runtime gem, resolved from Gemfile.lock via gemset.nix.
      # Regenerate both after any Gemfile change: `make gemset`.
      gemsFor =
        pkgs:
        pkgs.bundlerEnv {
          name = "mail2rss26-gems";
          ruby = rubyFor pkgs;
          gemdir = ./.;
        };

      # Lifted out of the source rather than repeated here, so the version in the
      # store path and the one `mail2rss26 --version` prints cannot disagree.
      version = lib.head (
        builtins.match ".*VERSION = \"([^\"]+)\".*" (builtins.readFile ./lib/mail2rss26.rb)
      );

      # What the program needs at run time, and nothing else. The Gemfile, the
      # Makefile, the README, `test/` and its fixtures are inputs to *developing*
      # this thing, not to running it, and every one of them would otherwise be
      # copied to the server inside the closure. `checks` below deliberately does
      # the opposite and builds from the whole of `self`, because the tests are
      # exactly what it needs.
      runtimeSrc = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.unions [
          ./bin
          ./lib
        ];
      };

      packageFor =
        pkgs:
        let
          ruby = rubyFor pkgs;
          gems = gemsFor pkgs;
        in
        pkgs.stdenv.mkDerivation {
          pname = "mail2rss26";
          inherit version;
          src = runtimeSrc;

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # Pure Ruby: there is nothing to configure and nothing to compile. That
          # is the whole payoff of "one gem, and it has no native extensions".
          dontConfigure = true;
          dontBuild = true;

          # bin/ and lib/ stay siblings because bin/mail2rss26 finds the library
          # by `File.expand_path("../lib", __dir__)`. They go under share/ rather
          # than straight into bin/, so that $out/bin holds exactly one file: the
          # wrapper, which is the only thing anyone should be running.
          installPhase = ''
            runHook preInstall

            mkdir -p $out/share/mail2rss26
            cp -r bin lib $out/share/mail2rss26/

            # Three deliberate things happen in this wrapper.
            #
            # 1. It `exec`s the interpreter — makeWrapper always does — so the
            #    Ruby process replaces the shell and *its* exit code is what
            #    OpenSMTPD reads. N3 is the whole error-handling design; a
            #    wrapper that returned its own status would quietly turn a
            #    deferred delivery into a discarded one.
            #
            # 2. GEM_PATH is *set*, not prefixed. It names the bundlerEnv and
            #    nothing else, which is the trap Phases 1 and 3 both walked into
            #    written down as a build artefact: the interpreter's own gem
            #    directory is off the search path, so anything that ships with
            #    Ruby as a *bundled* gem (rexml, minitest, csv…) raises LoadError
            #    here even though it imports fine in the dev shell. Only `mail`
            #    and default gems are reachable, which is exactly what lib/ uses.
            #    `checks.package` runs the built wrapper to prove it.
            #
            # 3. RUBYOPT and RUBYLIB are unset. They are "run this code first"
            #    and "look for code here" as environment variables; whatever
            #    OpenSMTPD's environment happens to hold has no business changing
            #    what runs during a delivery.
            makeWrapper ${ruby}/bin/ruby $out/bin/mail2rss26 \
              --add-flags $out/share/mail2rss26/bin/mail2rss26 \
              --set GEM_PATH ${gems}/${ruby.gemPath} \
              --unset RUBYOPT \
              --unset RUBYLIB

            runHook postInstall
          '';

          meta = {
            description = "Turns newsletters delivered by mail into Atom feeds";
            # No `homepage`, deliberately: this repository has no remote and no
            # public page, and a URL that resolves to nothing is worse than a
            # missing field. Same reason Phase 3 left `uri=` off the Atom
            # `<generator>`. Add one the day there is one.
            # So `nix run` knows which of $out/bin to run without guessing from
            # the derivation name — and so does the mda(8) line in Phase 6.
            mainProgram = "mail2rss26";
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (pkgs: {
        default = packageFor pkgs;
      });

      devShells = forAllSystems (pkgs: {
        default =
          let
            ruby = rubyFor pkgs;
            gems = gemsFor pkgs;
          in
          pkgs.mkShell {
            packages = [
              ruby
              pkgs.bundler
              # Turns Gemfile.lock into gemset.nix — `make gemset`. Needed only
              # when the Gemfile changes, which is why it is a dev-shell tool and
              # never a dependency of the package.
              pkgs.bundix
            ];

            # Same trick the test derivation uses, for the same reason: the gems
            # come from the store, the stdlib ones from the interpreter, and
            # `ruby -Ilib -Itest test/run.rb` works the moment the shell opens.
            #
            # Note that this is *wider* than what the packaged wrapper gets: the
            # second directory is the interpreter's own, which holds minitest and
            # rexml. The tests may use those. lib/ may not — see the wrapper.
            #
            # This needs gemset.nix to exist. If it is ever missing, bootstrap
            # with `nix run nixpkgs#bundix` outside the shell.
            GEM_PATH = "${gems}/${ruby.gemPath}:${ruby}/${ruby.gemPath}";
          };
      });

      checks = forAllSystems (pkgs: {
        # The fast loop: the Minitest suite as a plain derivation, so it runs
        # without KVM (N5). The nixosTest — the one check that does need KVM —
        # joins these in Phase 6.
        tests =
          let
            ruby = rubyFor pkgs;
            gems = gemsFor pkgs;
          in
          pkgs.runCommand "mail2rss26-tests"
            {
              nativeBuildInputs = [ ruby ];

              # Two directories, both needed: the first holds `mail`, the second
              # the gems that ship with the interpreter — Minitest among them.
              # Setting GEM_PATH at all drops the interpreter's own directory
              # from the search path, so it has to be named explicitly.
              GEM_PATH = "${gems}/${ruby.gemPath}:${ruby}/${ruby.gemPath}";
            }
            ''
              cp -r ${self} source
              chmod -R u+w source
              cd source
              ruby -Ilib -Itest test/run.rb
              touch $out
            '';

        # The one thing the suite above cannot tell us: whether the *packaged*
        # program runs anywhere other than a dev shell. It exercises the library
        # with the interpreter's gem directory in reach; the server will not have
        # it. That difference is a LoadError halfway through a delivery, which is
        # the single most expensive way to find out, so it is checked here.
        #
        # `env -i` is the point of the whole derivation: no PATH, no GEM_PATH,
        # no RUBYLIB, nothing the build environment set — the wrapper has to
        # carry everything itself, exactly as it will under an mda(8) line.
        package =
          let
            mail2rss26 = lib.getExe (packageFor pkgs);
          in
          pkgs.runCommand "mail2rss26-package" { } ''
            mkdir -p state
            cat > feeds.json <<'JSON'
            { "version": 1,
              "feeds": { "lamplighter": { "title": "The Lamplighter",
                                          "id": "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21",
                                          "addresses": ["weekly.a41f9d@feeds.lasocha.net"] } } }
            JSON

            echo "--- ingest: one message, filed and rendered"
            env -i ${mail2rss26} ingest \
              --config "$PWD/feeds.json" --state-dir "$PWD/state" \
              --recipient weekly.a41f9d@feeds.lasocha.net \
              < ${self}/test/fixtures/simple-multipart.eml

            test -f state/lamplighter/atom.xml
            grep -q '<feed xmlns="http://www.w3.org/2005/Atom">' state/lamplighter/atom.xml
            test "$(find state/lamplighter -name '*.eml' | wc -l)" -eq 1

            echo "--- render: the other command, loading the same code by another path"
            env -i ${mail2rss26} render \
              --config "$PWD/feeds.json" --state-dir "$PWD/state"

            echo "--- N3: a non-zero exit has to survive the wrapper unchanged"
            # If a wrapper ever swallowed this, OpenSMTPD would be told a failed
            # delivery succeeded and the newsletter would be gone rather than
            # queued. 67 is EX_NOUSER — an address no feed claims.
            code=0
            env -i ${mail2rss26} ingest \
              --config "$PWD/feeds.json" --state-dir "$PWD/state" \
              --recipient nobody@example.invalid < /dev/null || code=$?
            test "$code" -eq 67 || { echo "expected EX_NOUSER (67), got $code" >&2; exit 1; }

            touch $out
          '';
      });
    };
}
