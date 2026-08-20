# frozen_string_literal: true

module Mail2rss26
  VERSION = "0.1.0"

  # Where messages live: <state dir>/<feed>/<timestamp>-<id>.eml, plus the
  # rendered feed next to them. Overridable from the command line and from the
  # config file so tests can point at a temporary directory; the real value
  # comes from the NixOS module. Store owns everything about the layout below
  # this path.
  DEFAULT_STATE_DIR = "/var/lib/mail2rss26"
end

require "mail2rss26/store"
require "mail2rss26/message"
require "mail2rss26/feed"
require "mail2rss26/config"
require "mail2rss26/cli"
