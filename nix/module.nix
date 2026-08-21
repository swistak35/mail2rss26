# The NixOS module: a system user, a state directory, a feed list on disk, and
# the exact command OpenSMTPD is supposed to run.
#
# It is deliberately *thin*, and that is a recorded decision rather than an
# accident of it being early. The domain, the nginx vhost, the ACME entry and
# the whole of `smtpd.conf` stay in the consuming repository (Rivendell's
# `modules/newsletters.nix`), because a module that lives in someone else's
# flake drifts towards being an option framework all by itself, and Rivendell's
# own conventions say in as many words not to let that happen. Four settable
# options is the budget; everything else here is either derived from them or a
# read-only value the consumer would otherwise have to hard-code twice.
#
# What the consumer writes, in full:
#
#   services.mail2rss26 = {
#     enable = true;
#     feeds.lamplighter = {
#       title = "The Lamplighter";
#       id = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21";
#       url = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom";
#       addresses = [ "weekly.a41f9d@feeds.lasocha.net" ];
#     };
#   };
#
#   services.opensmtpd.serverConfiguration = with config.services.mail2rss26; ''
#     listen on eth0
#     table m2r_addresses { ${lib.concatMapStringsSep ", " (a: ''"${a}"'') addresses} }
#     table m2r_virtual { ${lib.concatMapStringsSep ", " (a: ''"${a}" = ${user}'') addresses} }
#     action "m2r" mda "${mdaCommand}" virtual <m2r_virtual> user ${user}
#     match from any for rcpt-to <m2r_addresses> action "m2r"
#   '';
#
# Both tables, and they are not redundant. The *list* is what the `match` rule
# tests, and an envelope matching no rule is what produces the "550 Invalid
# recipient" F5 asks for. The *mapping* is what OpenSMTPD expands the recipient
# through: without it, it looks the local part up in the system user database
# and permfails, because there is no user called `weekly.a41f9d` — and `user`
# on the action does not save you, it only skips the .forward lookup. That is
# the least obvious fact in this whole phase; nix/vm-test.nix is where it is
# demonstrated rather than asserted.
#
# `self` is threaded in so that `package` can default to the very flake this
# module came out of; a consumer that enables the module never names it.
{ self }:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.mail2rss26;

  # Exactly the schema Phase 4 fixed and `lib/mail2rss26/config.rb` validates:
  # version 1, `feeds` keyed by feed name. The object-keyed shape was chosen
  # precisely because it is what `attrsOf submodule` serialises to, so this is
  # one `toJSON` of the option and nothing else.
  #
  # `url` is dropped when null rather than written as JSON null. Both are
  # accepted on the Ruby side; a file with no key at all is the one a human
  # reads correctly.
  feedsJson = pkgs.writers.writeJSON "mail2rss26-feeds.json" {
    version = 1;
    stateDir = cfg.stateDir;
    feeds = lib.mapAttrs (
      _name: feed:
      lib.filterAttrs (_: value: value != null) {
        inherit (feed)
          title
          id
          url
          addresses
          ;
      }
    ) cfg.feeds;
  };

  # A feed name becomes a directory under stateDir, so it has to survive being
  # one. Same pattern as Config::NAME_PATTERN — the Ruby is the enforcement,
  # this is the early warning, and the difference between them is a `nix flake
  # check` on the consuming machine versus a newsletter deferred at 3am.
  namePattern = "^[a-z0-9][a-z0-9_-]*$";

  allAddresses = lib.concatMap (feed: feed.addresses) (lib.attrValues cfg.feeds);
in
{
  options.services.mail2rss26 = {
    enable = lib.mkEnableOption "mail2rss26, newsletters delivered by mail and served as Atom feeds";

    # Defaulted from `self`, so the consumer adds an input and enables a module
    # and never has to say the word "package". It stays settable because that
    # is the door for `--override-input`-style iteration and for a consumer
    # that wants to override the derivation; `lib.getExe` reads `mainProgram`
    # off whatever ends up here.
    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalMD "the `packages.default` of the mail2rss26 flake";
      description = "The mail2rss26 package to deliver and render with.";
    };

    # Settable because nginx has to be pointed at it from the other repository
    # and reading it out of this option beats spelling the same path in two
    # flakes. State, not configuration: nothing here is ever regenerated from
    # Nix, and Phase 8 of Rivendell backs this directory up.
    stateDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/mail2rss26";
      description = ''
        Where the stored `.eml` messages and the rendered `atom.xml` live, one
        directory per feed. Served directly by nginx; nothing else writes here.
      '';
    };

    # The one option that could not be avoided: `feeds.json` has to be
    # generated from *something*, and the schema Phase 4 fixed is exactly an
    # `attrsOf submodule`. Everything in the submodule is one of the three
    # tokens of the plan's central decision, or the title a human reads.
    feeds = lib.mkOption {
      default = { };
      description = ''
        The feeds to serve, keyed by feed name. The name becomes a directory
        under {option}`services.mail2rss26.stateDir` and must match
        `[a-z0-9][a-z0-9_-]*`.
      '';
      example = lib.literalExpression ''
        {
          lamplighter = {
            title = "The Lamplighter";
            id = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21";
            url = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom";
            addresses = [ "weekly.a41f9d@feeds.lasocha.net" ];
          };
        }
      '';
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            title = lib.mkOption {
              type = lib.types.str;
              description = "What a reader shows for this feed. Becomes the Atom `<title>`.";
            };

            id = lib.mkOption {
              type = lib.types.str;
              example = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21";
              description = ''
                The feed's Atom `<id>`. **Permanent**: it must never change once
                a reader has seen it, or every subscriber is shown a year of
                archive again as unread. In particular it is not derived from
                {option}`url`, which is rotatable, and not from
                {option}`addresses`, which are public.
              '';
            };

            url = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom";
              description = ''
                The public URL, written into the feed as `<link rel="self">`.
                Omit it and the feed is still valid, just without that link.

                This is the rotatable secret of the three tokens, and today it
                lands verbatim in the world-readable Nix store — the store path
                behind `/etc/mail2rss26/feeds.json`. Whether it should instead
                come from sops is an open question this module deliberately
                does not answer. It also does not stand in the way of the
                answer: the file is a plain `environment.etc` entry, so a
                consumer that grows a secret store can replace the whole thing
                with a rendered-at-activation template and change nothing else —

                ```nix
                environment.etc."mail2rss26/feeds.json".source =
                  lib.mkForce config.sops.templates."mail2rss26-feeds.json".path;
                ```
              '';
            };

            addresses = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              example = [ "weekly.a41f9d@feeds.lasocha.net" ];
              description = ''
                The incoming addresses this feed accepts, as full
                `local@domain`. Keep them inside `[a-z0-9.-]`: OpenSMTPD
                replaces characters it considers suspicious with `:` before the
                delivery agent ever sees the recipient, so a wider alphabet can
                only ever produce an address that matches nothing.
              '';
            };
          };
        }
      );
    };

    # --- Read-only outputs -------------------------------------------------
    # Not knobs. They exist so that the OpenSMTPD configuration in the *other*
    # repository can be written without hard-coding a single string this module
    # owns — which is the one failure this module is actually in a position to
    # prevent. `feeds.json` and `smtpd.conf` disagreeing is what produces an
    # EX_NOUSER in production — the one failure this program *bounces* rather
    # than defers — and the README calls it unreachable precisely because both
    # sides are supposed to come from here.

    user = lib.mkOption {
      type = lib.types.str;
      default = "mail2rss26";
      readOnly = true;
      description = ''
        The system user deliveries run as: the `user` keyword of the
        OpenSMTPD `action` that names {option}`mdaCommand`.
      '';
    };

    mdaCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${lib.getExe cfg.package} ingest --recipient '%{rcpt}'";
      defaultText = lib.literalExpression ''"''${lib.getExe cfg.package} ingest --recipient '%{rcpt}'"'';
      description = ''
        The command to hand to `action <name> mda "…"` in `smtpd.conf`.

        Three things about it are load-bearing.

        The path is absolute because it has to be: OpenSMTPD runs the command
        as `/bin/sh -c` with `PATH=/usr/bin:/bin` (`_PATH_DEFPATH`, compiled
        into `mda_unpriv.c`), and on NixOS those two directories hold
        `/usr/bin/env` and `/bin/sh` and nothing else at all.

        `%{rcpt}` is the *envelope* recipient, in full `local@domain` form,
        which is what `ingest` requires — a bare local part matches no feed.

        It is wrapped in single quotes because it is expanded into a shell
        command line. OpenSMTPD sanitises format specifiers by replacing every
        character of `!#$%&'*?`{|}~` with `:` (`MAILADDR_ESCAPE` in
        `smtpd.h`), so the expansion can never contain a `'` and single quotes
        are airtight. It says nothing about spaces or double quotes, which that
        set does *not* cover, so the quotes are not decoration.
      '';
    };

    addresses = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      readOnly = true;
      default = lib.sort (a: b: a < b) (lib.unique allAddresses);
      defaultText = lib.literalMD "every address of every configured feed";
      description = ''
        Every configured incoming address, flattened and sorted. It feeds the
        two `smtpd.conf` tables the delivery needs, and they do different jobs:

        the *list* table is what `match … for rcpt-to <…>` tests, so an address
        no feed claims matches no rule and is refused with `550 Invalid
        recipient` during the SMTP dialogue (F5) rather than being accepted,
        queued and then rejected by `ingest`;

        the *mapping* table, which pairs every address with the {option}`user`
        below, is what `virtual <…>` on the action expands the recipient
        through.
        Without it OpenSMTPD looks the local part up in the system user
        database and refuses the recipient, because no user is called
        `weekly.a41f9d`. The `user` keyword does not help — it only skips the
        `.forward` lookup.

        See the example at the top of this file, and `nix/vm-test.nix` for the
        same configuration with a machine around it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Both of these are checked again by Config on every delivery. They are
    # here as well because a `nix flake check` on the consuming machine is a
    # cheaper place to find out than a queue filling up with deferred
    # newsletters and a config error repeated once per delivery in the mail log.
    assertions = [
      {
        assertion = lib.all (name: builtins.match namePattern name != null) (lib.attrNames cfg.feeds);
        message =
          "services.mail2rss26.feeds: every feed name becomes a directory and must match "
          + "${namePattern}; offending: "
          + lib.concatStringsSep ", " (
            lib.filter (name: builtins.match namePattern name == null) (lib.attrNames cfg.feeds)
          );
      }
      {
        assertion = lib.all (feed: feed.addresses != [ ]) (lib.attrValues cfg.feeds);
        message = "services.mail2rss26.feeds: a feed with no addresses can never receive anything.";
      }
      {
        # Guessing which feed a shared address belongs to would file somebody's
        # newsletter in the wrong place forever, so neither side guesses.
        assertion = lib.length (lib.unique allAddresses) == lib.length allAddresses;
        message = "services.mail2rss26.feeds: an address is claimed by two feeds.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.user;
      description = "mail2rss26 newsletter feeds";
      # OpenSMTPD chdir()s into the delivery user's home and exports it as
      # $HOME. Pointing it at the state directory means the one thing this user
      # can write to is also where it lands.
      home = cfg.stateDir;
    };

    # Its own group rather than a shared one: nothing else has any business
    # writing here, and nginx does not need to be in it — the directory is
    # world-readable and the files are 0644, because the secret is the URL and
    # not the bytes behind it.
    users.groups.${cfg.user} = { };

    systemd.tmpfiles.settings.mail2rss26.${cfg.stateDir}.d = {
      user = cfg.user;
      group = cfg.user;
      mode = "0755";
    };

    # `/etc/mail2rss26/feeds.json` is Config::DEFAULT_PATH, which is what keeps
    # the mda(8) line down to one option. See the `url` description above for
    # why this is an ordinary etc entry and not something cleverer.
    environment.etc."mail2rss26/feeds.json".source = feedsJson;

    # For the operator, not for the service: `sudo -u mail2rss26 mail2rss26
    # render --feed x` on a machine that is misbehaving. It is already in the
    # closure, so this costs a symlink.
    environment.systemPackages = [ cfg.package ];

    # Renders every configured feed at boot and after any change to the feed
    # list. Three things fall out of it, and all three are otherwise missing:
    #
    #   a brand-new feed exists as a valid empty document the moment it is
    #   deployed, instead of 404ing until its first newsletter arrives;
    #
    #   a retitled feed or a rotated URL reaches the file readers fetch without
    #   waiting for the next delivery;
    #
    #   a feeds.json that does not satisfy the schema fails here, loudly, at
    #   the same `nixos-rebuild switch` that introduced it, rather than during
    #   a delivery hours later.
    #
    # Rendering asks the clock nothing (N6), so a run that changes nothing
    # rewrites byte-identical files and no reader is told anything happened.
    systemd.services.mail2rss26-render = {
      description = "Render every mail2rss26 Atom feed";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];

      # Without this the unit is unchanged when only the feed list changed, and
      # a oneshot with RemainAfterExit that is unchanged is not restarted — so
      # the switch that retitled a feed would not re-render it.
      restartTriggers = [ feedsJson ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        Group = cfg.user;
        ExecStart = "${lib.getExe cfg.package} render";

        # N1 and N2 as something the kernel enforces rather than something the
        # program promises: this thing has no reason to open a socket, ever.
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
  };
}
