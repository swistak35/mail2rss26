# frozen_string_literal: true

module Mail2rss26
  VERSION = "0.1.0"

  # Where messages live: <state dir>/<feed>/<timestamp>-<id>.eml, plus the
  # rendered feed. Overridable on the command line so tests can point at a
  # temporary directory; the real value comes from the NixOS module.
  DEFAULT_STATE_DIR = "/var/lib/mail2rss26"
end

require "mail2rss26/cli"
