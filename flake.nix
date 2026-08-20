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
      # One server and one workstation, both x86_64-linux. Another platform is one
      # more string here, not a refactor.
      systems = [ "x86_64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # Which interpreter the gems, the tests and (from Phase 5) the package are
      # built against. Named once so they cannot drift apart.
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
    in
    {
      packages = forAllSystems (pkgs: {
        # Placeholder. Real packaging (bundlerEnv + a wrapper pinning GEM_PATH,
        # and a closure with no bundix and no tests in it) is Phase 5; until then
        # this exists so `packages.default` is a stable attribute to build against
        # and fails loudly rather than pretending to work.
        default = pkgs.writeShellScriptBin "mail2rss26" ''
          echo "mail2rss26: not packaged yet — see Phase 5 of the plan." >&2
          exit 1
        '';
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
      });
    };
}
