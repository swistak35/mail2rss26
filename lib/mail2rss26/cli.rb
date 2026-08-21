# frozen_string_literal: true

require "optparse"

require "mail2rss26/config"
require "mail2rss26/feed"
require "mail2rss26/message"
require "mail2rss26/store"

module Mail2rss26
  # The two commands, and the exit codes they answer with.
  #
  # The exit code is an *instruction to OpenSMTPD*, not a comment in the log.
  # smtpd.c decides on it directly: EX_OSERR (71) and EX_TEMPFAIL (75) mean
  # "keep this envelope and try again", and every other non-zero status means
  # "give up, bounce it, the message is gone". A code chosen for how well it
  # describes the failure — the sysexits(3) way — therefore throws newsletters
  # away whenever the well-describing number is not one of those two.
  #
  # So the only question a failure here has to answer is: *must this message
  # survive?* If a corrected system (a fixed feeds.json, a fixed mda line, a
  # disk with room on it, a released bug fix) would deliver this exact envelope,
  # the answer is yes and the code is 75. The detail that a sysexits value would
  # have carried goes on stderr instead, which smtpd copies into the mail log
  # and into the bounce.
  #
  # The full table and the reasoning per row are in README.md. This is the
  # interface with OpenSMTPD, so changing any of it is changing a contract.
  module CLI
    EX_OK = 0

    # Defer: the envelope stays in OpenSMTPD's queue and is tried again (N3).
    #
    # This is the *only* non-zero code this program returns for a failure it or
    # an operator could still put right, and it is deliberately one number
    # rather than a vocabulary. 71 (EX_OSERR) defers identically and was
    # considered for the I/O cases; it was rejected because a second defer code
    # buys no behaviour, only the appearance of a taxonomy — and it was exactly
    # that appearance which made 74 look like a reasonable thing to return.
    EX_TEMPFAIL = 75

    # Bounce: the envelope leaves the queue and the sender is told.
    #
    # The one condition in this program that no operator action makes
    # deliverable: an address that names no feed. There is nothing to fix
    # except inventing a feed, F5 says the address should have been refused
    # with 550 during the dialogue anyway, and deferring it would only retry
    # until the queue expires it — a bounce four days late, and noisier.
    EX_NOUSER = 67

    # A mistake in the invocation, told apart from every ArgumentError a bug
    # might raise deeper down — those are worth a backtrace, and both end up
    # deferring anyway.
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
        # An empty argv is a broken mda(8) line as easily as it is a human at a
        # prompt, and this program cannot tell the two apart. The one that has
        # a newsletter riding on the answer decides it: defer, so the message
        # is still there once the line is fixed.
        command.nil? ? EX_TEMPFAIL : EX_OK
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
        EX_TEMPFAIL
      end
    rescue OptionParser::ParseError, UsageError => e
      # The mda(8) line is wrong: a renamed option, a missing --recipient, a
      # mistyped command word. Sixty-four says so precisely and would bounce
      # every newsletter that arrives until somebody notices — and what they
      # would notice is the absence of mail, which is the hardest thing there
      # is to notice. Deferring loses nothing instead: the operator edits
      # smtpd.conf, and the queue drains what it was holding. It is not silent
      # either, and the two places it shows are worth knowing: `smtpctl show
      # queue` stops being empty, and this message is in the mail log once per
      # delivery.
      stderr.puts "mail2rss26: #{e.message}"
      EX_TEMPFAIL
    rescue Config::Error => e
      # The feed list is missing, unreadable, not JSON, or fails the schema.
      # Exactly the same shape of problem as the line above, one file over —
      # and the envelope that hit it was accepted because smtpd.conf said the
      # address was good, so a corrected feeds.json delivers it. This is the
      # "OpenSMTPD's queue is our retry mechanism" payoff being collected.
      stderr.puts "mail2rss26: #{e.message}"
      EX_TEMPFAIL
    rescue SystemCallError, IOError => e
      # Everything the state directory and stdin can do to us: ENOSPC, EACCES,
      # EROFS, a broken pipe. The clearest defer of the lot, and the one the
      # old contract got exactly backwards by answering 74 (EX_IOERR) — the
      # single row it had marked "a retry helps" was the row that bounced.
      stderr.puts "mail2rss26: #{e.message}"
      EX_TEMPFAIL
    rescue StandardError => e
      # A bug. The backtrace goes to stderr on purpose — OpenSMTPD captures the
      # delivery agent's output into the log, so this is the only bug report we
      # are ever going to get.
      #
      # It defers, and this is the one row where that is a judgement call
      # rather than a deduction. A crash we did not classify may well be
      # deterministic in the bytes of this newsletter, in which case every
      # retry crashes the same way and the envelope expires in a few days —
      # deferring bought nothing but noise. But we cannot know that from here,
      # and the two ways of being wrong do not cost the same: defer a
      # permanent crash and we lose four days of queue and then bounce anyway;
      # bounce a crash somebody fixes this afternoon and the newsletter is
      # gone, unrecoverably, while the fix sits there. Undecidable plus
      # asymmetric costs is the situation N3 exists for.
      stderr.puts "mail2rss26: #{e.class}: #{e.message}"
      e.backtrace&.each { |line| stderr.puts "  #{line}" }
      EX_TEMPFAIL
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
        # zero bytes is not a message at all.
        #
        # It defers, which reverses Phase 4's reading ("the next attempt hands
        # over the same nothing", so 65, permanent). A message delivered over
        # SMTP cannot be zero bytes — DATA carries headers and smtpd stamps a
        # Received: of its own on top of them — so zero bytes on stdin never
        # means "this envelope is empty", it means the pipe or the mda line
        # between the queue and here is broken. The queue file still holds a
        # whole newsletter. Bouncing would throw it away on the strength of
        # evidence about our plumbing.
        stderr.puts "mail2rss26: nothing on stdin — no message to file for #{recipient}"
        return EX_TEMPFAIL
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
