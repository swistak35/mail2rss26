# frozen_string_literal: true

require "optparse"

require "mail2rss26/config"
require "mail2rss26/feed"
require "mail2rss26/message"
require "mail2rss26/store"

module Mail2rss26
  # The two commands, and the exit codes they answer with.
  #
  # The codes are the interface with OpenSMTPD and are documented in the README
  # as a contract, not as a detail — they are the only thing the mail system
  # ever learns about a delivery. The full table lives there; the short version
  # is that these are sysexits(3) values, that a non-zero exit keeps the message
  # in the queue, and that the split below says whether a retry has any chance
  # of a different answer.
  module CLI
    EX_OK = 0

    # Permanent. Nobody's disk is going to fix these.
    EX_USAGE = 64    # the command line is wrong: the mda(8) line needs editing
    EX_DATAERR = 65  # stdin held no message at all
    EX_NOUSER = 67   # no feed for this recipient (F5) or no such --feed
    EX_SOFTWARE = 70 # an exception we did not classify: a bug, with a backtrace
    EX_CONFIG = 78   # the feed list is missing, unreadable or malformed

    # Temporary. A retry is exactly the right thing.
    EX_IOERR = 74 # reading stdin or writing the state directory failed

    # Reserved, and deliberately never returned. It is the one code every
    # sendmail-derived MDA reads as "defer this", so no other meaning in this
    # program may ever be given the number 75.
    EX_TEMPFAIL = 75

    # A mistake in the invocation, told apart from every ArgumentError a bug
    # might raise deeper down — those are worth a backtrace and EX_SOFTWARE, not
    # a usage message.
    class UsageError < StandardError; end

    COMMANDS = %w[ingest render].freeze

    BANNER = <<~USAGE
      Usage: mail2rss26 <command> [options]

      Commands:
          ingest    Read one message on stdin and file it under a feed
          render    Rebuild a feed's atom.xml from the messages on disk

      Run `mail2rss26 <command> --help` for the options of a command.
    USAGE

    module_function

    # Returns an exit code rather than calling exit, so the tests can drive it.
    def run(argv, stdout: $stdout, stderr: $stderr, stdin: $stdin)
      command = argv.first

      case command
      when nil, "-h", "--help", "help"
        stdout.puts BANNER
        command.nil? ? EX_USAGE : EX_OK
      when "--version"
        stdout.puts "mail2rss26 #{VERSION}"
        EX_OK
      when "ingest"
        ingest(parse_ingest(argv.drop(1)), stdin: stdin, stderr: stderr)
      when "render"
        render(parse_render(argv.drop(1)), stderr: stderr)
      else
        stderr.puts "mail2rss26: unknown command #{command.inspect}"
        stderr.puts BANNER
        EX_USAGE
      end
    rescue OptionParser::ParseError, UsageError => e
      stderr.puts "mail2rss26: #{e.message}"
      EX_USAGE
    rescue Config::Error => e
      stderr.puts "mail2rss26: #{e.message}"
      EX_CONFIG
    rescue SystemCallError, IOError => e
      # Everything the state directory and stdin can do to us: ENOSPC, EACCES,
      # EROFS, a broken pipe. All of it is our side failing, all of it is
      # plausibly gone by the next attempt, so it is the temporary code and the
      # message stays in the queue.
      stderr.puts "mail2rss26: #{e.message}"
      EX_IOERR
    rescue StandardError => e
      # A bug. The backtrace goes to stderr on purpose — OpenSMTPD captures the
      # delivery agent's output into the log, so this is the only bug report we
      # are ever going to get — and the exit code is still non-zero, so the
      # newsletter is still in the queue when the bug is fixed (N3).
      stderr.puts "mail2rss26: #{e.class}: #{e.message}"
      e.backtrace&.each { |line| stderr.puts "  #{line}" }
      EX_SOFTWARE
    end

    def parse_ingest(args)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 ingest --recipient ADDRESS [options] < message.eml"
        o.on("--recipient ADDRESS", "Envelope recipient the message was delivered to") do |v|
          options[:recipient] = v
        end
        o.on("--config PATH", "Feed list (default: #{Config::DEFAULT_PATH})") do |v|
          options[:config] = v
        end
        o.on("--state-dir DIR", "Where feeds and messages live (default: #{DEFAULT_STATE_DIR})") do |v|
          options[:state_dir] = v
        end
      end
      parser.parse!(args)

      raise UsageError, "ingest: --recipient is required" if options[:recipient].nil?
      raise UsageError, "ingest: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    def parse_render(args)
      options = {}

      parser = OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 render [--feed NAME] [options]"
        o.on("--feed NAME", "Feed to re-render; omit to re-render every feed") do |v|
          options[:feed] = v
        end
        o.on("--config PATH", "Feed list (default: #{Config::DEFAULT_PATH})") do |v|
          options[:config] = v
        end
        o.on("--state-dir DIR", "Where feeds and messages live (default: #{DEFAULT_STATE_DIR})") do |v|
          options[:state_dir] = v
        end
      end
      parser.parse!(args)

      raise UsageError, "render: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    # F1, end to end: one message on stdin, filed under the feed the recipient
    # names, and the feed re-rendered on the way out.
    def ingest(options, stdin: $stdin, stderr: $stderr)
      config = Config.load(Config.path(options[:config]))
      recipient = options.fetch(:recipient)

      feed = config.feed_for(recipient)
      if feed.nil?
        stderr.puts(*unknown_recipient(recipient, config))
        return EX_NOUSER
      end

      raw = read_message(stdin)
      if raw.strip.empty?
        # Not "a malformed message", which Phase 2 settled is not an error:
        # zero bytes is not a message at all, and it is our side of the
        # conversation that is broken. Retrying will produce zero bytes again,
        # hence the permanent code.
        stderr.puts "mail2rss26: nothing on stdin — no message to file for #{recipient}"
        return EX_DATAERR
      end

      # The clock, once, here, and nowhere else in this program.
      #
      # This is not the N6 violation it looks like. N6 is about *rendering*: the
      # same files must always produce the same feed, and they do, because this
      # instant is written into the stored filename and read back out of it at
      # every later render. Delivery is where an event genuinely happens, and
      # the only source for "when" is the clock. What would break N6 is asking
      # the clock while rendering — nothing does.
      now = Time.now.utc
      message = Message.parse(raw, fallback_date: now)

      store = Store.new(state_dir(options, config))
      store.with_feed(feed) do |dir|
        # nil means the message was already on disk: F6 before the renderer
        # ever gets involved. The feed is re-rendered anyway — it costs one
        # directory listing and it is how a feed that failed to render last
        # time gets a second chance — and the result is byte-identical.
        store.store(dir, message.date, message.message_id, raw)
        write_feed(feed, dir)
      end

      EX_OK
    end

    # The same render `ingest` does, without a delivery. For a configuration
    # change (a retitled feed, a rotated URL), for a restored backup, and for
    # bringing a brand-new feed into existence before its first newsletter.
    def render(options, stderr: $stderr)
      config = Config.load(Config.path(options[:config]))

      feeds = config.feeds
      if options[:feed]
        feed = config.feed_named(options[:feed])
        if feed.nil?
          stderr.puts "mail2rss26: no feed named #{options[:feed].inspect} in #{config.path}"
          return EX_NOUSER
        end
        feeds = [feed]
      end

      store = Store.new(state_dir(options, config))
      feeds.each { |feed| store.with_feed(feed) { |dir| write_feed(feed, dir) } }

      EX_OK
    end

    # --state-dir wins, then the config file, then the compiled-in default. The
    # middle one exists so the OpenSMTPD mda(8) line can stay down to
    # `mail2rss26 ingest --recipient %{rcpt}`: everything else the delivery
    # needs is already in the file the NixOS module generates.
    def state_dir(options, config)
      options[:state_dir] || config.state_dir || DEFAULT_STATE_DIR
    end

    def write_feed(feed, dir)
      Feed.from_directory(dir, id: feed.id, title: feed.title, self_url: feed.url)
          .write(Store.atom_path(dir))
    end

    def read_message(stdin)
      # Binary in, binary out: the .eml on disk has to be the bytes OpenSMTPD
      # handed over, byte for byte, or the sha256: Message-ID fallback (and
      # therefore F6) means something different on the second delivery.
      stdin.binmode if stdin.respond_to?(:binmode)
      (stdin.read || "").b
    end

    # F5 says this should have been refused with 550 during the SMTP dialogue,
    # so reaching here at all means smtpd.conf and the feed list disagree — and
    # that is what the message has to say, because the fix is in one of those
    # two files and not in this program.
    def unknown_recipient(recipient, config)
      lines = ["mail2rss26: no feed is configured for #{recipient.inspect} (nothing was written); " \
               "#{config.path} and the smtpd.conf rules disagree"]

      if recipient.include?(":")
        # OpenSMTPD replaces characters it considers suspicious with ":" when it
        # expands %{rcpt}, so a colon here is usually not a colon in the
        # address — it is the shape of one that never should have been minted.
        lines << "mail2rss26: the address contains ':', which is what OpenSMTPD substitutes for " \
                 "characters it finds suspicious — feed addresses should stay within [a-z0-9.-]"
      end

      lines
    end
  end
end
