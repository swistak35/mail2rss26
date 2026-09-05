# frozen_string_literal: true

require "optparse"

require "mail2rss26/config"
require "mail2rss26/feed"
require "mail2rss26/journal"
require "mail2rss26/message"
require "mail2rss26/store"
require "mail2rss26/viewer"

module Mail2rss26
  # The commands, and the exit codes they answer with.
  #
  # Two of them are the delivery path — `ingest`, which OpenSMTPD runs, and
  # `render`, which systemd runs — and everything below about exit codes is
  # about those. The other three (`log`, `show`, `feeds`) are for a person on
  # the server and are governed by nothing here except EX_FAILURE.
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

    # Not part of the contract above, and deliberately outside its vocabulary:
    # `log`, `show` and `feeds` are run by a person at a terminal and never by
    # a mail system, so there is no envelope whose fate a number decides. One
    # is the shell's ordinary "that did not work".
    #
    # It is worth being explicit that this does not widen the delivery
    # contract. Nothing reached from `ingest` may ever return this.
    EX_FAILURE = 1

    # A mistake in the invocation, told apart from every ArgumentError a bug
    # might raise deeper down — those are worth a backtrace, and both end up
    # deferring anyway.
    class UsageError < StandardError; end

    DELIVERY_COMMANDS = %w[ingest render].freeze
    OPERATOR_COMMANDS = %w[log show feeds].freeze
    COMMANDS = (DELIVERY_COMMANDS + OPERATOR_COMMANDS).freeze

    BANNER = <<~USAGE
      Usage: mail2rss26 <command> [options]

      Delivery (what OpenSMTPD and systemd run):
          ingest    Read one message on stdin and file it under a feed
          render    Rebuild a feed's atom.xml from the messages on disk

      Inspection (what you run on the server):
          log       What has been delivered, and what was done with it
          show      Everything known about one delivery
          feeds     Every configured feed, what it holds and when it last heard anything

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
      when *OPERATOR_COMMANDS
        # Their own rescue, so a missing feed list while somebody is reading
        # the log answers "1, and here is why" instead of borrowing 75 from a
        # contract about envelopes that are not involved.
        operator(command, argv.drop(1), stdout: stdout, stderr: stderr)
      else
        stderr.puts "mail2rss26: unknown command #{command.inspect}"
        stderr.puts BANNER
        # Deferring rather than bouncing for the same reason the empty argv
        # above does: a typo in the mda(8) line reaches here.
        deferred(argv, "usage", "unknown command #{command.inspect}", stderr)
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
      deferred(argv, "usage", e.message, stderr)
    rescue Config::Error => e
      # The feed list is missing, unreadable, not JSON, or fails the schema.
      # Exactly the same shape of problem as the line above, one file over —
      # and the envelope that hit it was accepted because smtpd.conf said the
      # address was good, so a corrected feeds.json delivers it. This is the
      # "OpenSMTPD's queue is our retry mechanism" payoff being collected.
      stderr.puts "mail2rss26: #{e.message}"
      deferred(argv, "config", e.message, stderr)
    rescue SystemCallError, IOError => e
      # Everything the state directory and stdin can do to us: ENOSPC, EACCES,
      # EROFS, a broken pipe. The clearest defer of the lot, and the one the
      # old contract got exactly backwards by answering 74 (EX_IOERR) — the
      # single row it had marked "a retry helps" was the row that bounced.
      stderr.puts "mail2rss26: #{e.message}"
      deferred(argv, "io", e.message, stderr)
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
      deferred(argv, "crash", "#{e.class}: #{e.message}", stderr)
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
      journal = Journal.new(state_dir(options, config), stderr: stderr)

      feed = config.feed_for(recipient)
      if feed.nil?
        stderr.puts(*unknown_recipient(recipient, config))
        # The message is still read and parsed, even though not one byte of it
        # will be kept. It costs nothing (it was going to be discarded either
        # way) and it turns the journal line from "somebody sent something to
        # an address we do not have" into one naming the sender and the
        # subject — which is what tells a retired newsletter apart from a
        # stranger guessing addresses, and which of the two the drift between
        # smtpd.conf and feeds.json actually is.
        journal.record(**refusal(recipient, stdin))
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
        journal.record(outcome: "deferred", exit: EX_TEMPFAIL, recipient: recipient, feed: feed.name,
                       reason: "empty-stdin", error: "nothing on stdin")
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
      filed = nil
      duplicate = false

      store.with_feed(feed) do |dir|
        # An existing file means the message was already on disk: F6 before the
        # renderer ever gets involved. The feed is re-rendered anyway — it costs
        # one directory listing and it is how a feed that failed to render last
        # time gets a second chance — and the result is byte-identical.
        existing = store.find(dir, message.message_id)
        duplicate = !existing.nil?
        filed = existing || File.basename(store.store(dir, message.date, message.message_id, raw))
        write_feed(feed, dir)
      end

      # After the feed lock is released, never inside it. Two locks held at
      # once want a documented order, and the way not to need one is not to do
      # it: nothing about writing the journal has anything to say to the feed
      # directory. A failure here does not fail the delivery — see Journal.
      journal.record(**delivery(recipient, feed, message, raw, file: filed, duplicate: duplicate))

      EX_OK
    end

    # The journal line for a delivery that landed. `match` records *how* the
    # address resolved, because "the tag was stripped" is the difference
    # between a feed that is configured correctly and one that works by
    # accident.
    def delivery(recipient, feed, message, raw, file:, duplicate:)
      {
        outcome: duplicate ? "duplicate" : "stored",
        exit: EX_OK,
        recipient: recipient,
        feed: feed.name,
        match: feed.addresses.include?(Config.normalise(recipient)) ? "exact" : "tag",
        file: file
      }.merge(described(message, raw))
    end

    # The journal line for a refusal. No feed, so no directory and no file —
    # only what the bytes said about themselves, and only if they could be read
    # at all: a broken pipe here must not turn a bounce into a deferral, so the
    # metadata is optional and the exit code is not.
    def refusal(recipient, stdin)
      fields = { outcome: "no-feed", exit: EX_NOUSER, recipient: recipient }

      begin
        raw = read_message(stdin)
        fields.merge!(described(Message.parse(raw), raw)) unless raw.strip.empty?
      rescue StandardError # rubocop:disable Lint/SuppressedException
      end

      fields
    end

    # What a human needs to recognise a message in a list, and the two facts
    # about it that are invisible in the .eml itself: which part became the
    # entry, and where its date came from.
    def described(message, raw)
      {
        # The Message-ID is in here rather than alongside `file` so that a
        # *refused* delivery carries one too. It is the only handle such a
        # delivery has — there is no file to name it by — and without it the
        # one outcome you most want to look up is the one `show` cannot find.
        message_id: message.message_id,
        from: Journal.truncate(message.author_email || message.author),
        subject: Journal.truncate(message.title),
        date: Journal.timestamp(message.date),
        date_source: message.date_source,
        bytes: raw.bytesize,
        body: message.body.empty? ? "empty" : (message.html? ? "html" : "text")
      }
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

    # --- the operator's commands ---------------------------------------------
    #
    # Read-only, every one of them. They open the journal, the stored .eml
    # files and the rendered atom.xml and print; nothing here creates, moves or
    # deletes anything, which is why none of them needs a lock and why running
    # one during a delivery is safe.

    def operator(command, args, stdout: $stdout, stderr: $stderr)
      case command
      when "log"
        options = parse_log(args)
        # A feed list is wanted but not required here, and that is deliberate:
        # `log` is exactly the command you reach for when feeds.json is the
        # thing that is broken, and refusing to show the deferrals it caused
        # would be a poor joke.
        viewer(options, load_config_quietly(options[:config]), stdout, stderr)
          .log(feed: options[:feed], outcome: options[:outcome],
               since: options[:since], limit: options[:limit], json: options[:json])
        EX_OK
      when "show"
        options = parse_show(args)
        found = viewer(options, load_config_quietly(options[:config]), stdout, stderr)
                .show(options.fetch(:key), part: options[:part])
        found ? EX_OK : EX_FAILURE
      when "feeds"
        options = parse_feeds(args)
        # The one that genuinely cannot work without the file: it is a report
        # *about* the configured feeds. Config::Error lands in the rescue below
        # and becomes a message and a 1.
        config = Config.load(Config.path(options[:config]))
        viewer(options, config, stdout, stderr).feeds
        EX_OK
      end
    rescue Journal::Unreadable => e
      # Its own arm rather than a line in the one below, because the fix is
      # almost always a word the operator forgot rather than anything wrong
      # with the machine. `log` fails outright here — the journal *is* the
      # command — while `show` and `feeds` catch it themselves and carry on
      # with what they can read, since most of what they show is world
      # readable.
      stderr.puts "mail2rss26: #{e.message}"
      stderr.puts "mail2rss26: #{Viewer::SUDO_HINT}"
      EX_FAILURE
    rescue OptionParser::ParseError, UsageError, Config::Error, SystemCallError, IOError => e
      stderr.puts "mail2rss26: #{e.message}"
      EX_FAILURE
    end

    def viewer(options, config, stdout, stderr)
      Viewer.new(state_dir: options[:state_dir] || config&.state_dir || DEFAULT_STATE_DIR,
                 config: config, stdout: stdout, stderr: stderr)
    end

    def parse_log(args)
      options = { limit: 50 }

      OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 log [--feed NAME] [--outcome KIND] [--since WHEN] [--limit N] [--json]"
        o.on("--feed NAME", "Only deliveries to this feed") { |v| options[:feed] = v }
        o.on("--outcome KIND", "One of #{Journal::OUTCOMES.join(', ')}") do |v|
          raise UsageError, "log: unknown outcome #{v.inspect} (#{Journal::OUTCOMES.join(', ')})" unless
            Journal::OUTCOMES.include?(v)

          options[:outcome] = v
        end
        o.on("--since WHEN", "e.g. 30m, 12h, 7d, or 2026-09-01") { |v| options[:since] = since(v) }
        o.on("--limit N", Integer, "How many to show (default 50; 0 for all)") do |v|
          options[:limit] = v.positive? ? v : nil
        end
        o.on("--json", "One journal line per delivery, as stored") { options[:json] = true }
        common(o, options)
      end.parse!(args)

      raise UsageError, "log: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    def parse_show(args)
      options = { part: :summary }

      OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 show <message-id | file name | any part of one> [--raw|--headers|--body]"
        o.on("--raw", "Write the stored message out exactly as it arrived") { options[:part] = :raw }
        o.on("--headers", "Print the header block, undecoded") { options[:part] = :headers }
        o.on("--body", "Print the part that became the feed entry") { options[:part] = :body }
        common(o, options)
      end.parse!(args)

      raise UsageError, "show: name a message (its Message-ID, or part of its file name)" if args.empty?
      raise UsageError, "show: unexpected argument #{args[1].inspect}" if args.length > 1

      options.merge(key: args.first)
    end

    def parse_feeds(args)
      options = {}

      OptionParser.new do |o|
        o.banner = "Usage: mail2rss26 feeds"
        common(o, options)
      end.parse!(args)

      raise UsageError, "feeds: unexpected argument #{args.first.inspect}" unless args.empty?

      options
    end

    def common(parser, options)
      parser.on("--config PATH", "Feed list (default: #{Config::DEFAULT_PATH})") { |v| options[:config] = v }
      parser.on("--state-dir DIR", "Where feeds and messages live (default: #{DEFAULT_STATE_DIR})") do |v|
        options[:state_dir] = v
      end
    end

    # Durations relative to now, or a plain date. Deliberately small: this is a
    # filter on a log a person is reading, not a query language, and anything
    # it cannot parse is a UsageError rather than a silently ignored argument.
    def since(text)
      match = /\A(\d+)([mhd])\z/.match(text.to_s)
      if match
        seconds = { "m" => 60, "h" => 3600, "d" => 86_400 }.fetch(match[2])
        return Time.now.utc - (Integer(match[1], 10) * seconds)
      end

      date = /\A(\d{4})-(\d{2})-(\d{2})\z/.match(text.to_s)
      raise UsageError, "log: cannot read #{text.inspect} as a time (try 30m, 12h, 7d or 2026-09-01)" unless date

      Time.utc(*date.captures.map { |part| Integer(part, 10) })
    rescue ArgumentError
      raise UsageError, "log: #{text.inspect} is not a date"
    end

    def load_config_quietly(path)
      Config.load(Config.path(path))
    rescue Config::Error
      nil
    end

    # --- the journal on the failure paths -------------------------------------

    # Every deferral out of `run`'s rescue chain comes through here, so that the
    # failures which leave *nothing* behind — a broken mda line, an unreadable
    # feed list, a crash — are the ones the journal is most careful to record.
    # They are also the ones nobody would otherwise notice: a deferring delivery
    # looks exactly like a quiet week.
    #
    # Only for `ingest`. A failed `render` is a failed systemd unit and shows up
    # as one; a failed `log` is a person seeing an error on their terminal.
    def deferred(argv, reason, message, stderr)
      if argv.first == "ingest"
        Journal.new(failure_state_dir(argv), stderr: stderr)
               .record(outcome: "deferred", exit: EX_TEMPFAIL, reason: reason,
                       recipient: flag(argv, "--recipient"), error: Journal.truncate(message))
      end

      EX_TEMPFAIL
    end

    # Where to write when the ordinary way of finding out has already failed —
    # which is the situation by definition here, since one of the things that
    # brings us to this path is a feeds.json that will not load. The explicit
    # flag first, then the config if it happens to be readable, then the
    # compiled-in default, which is the right answer on the real machine.
    def failure_state_dir(argv)
      explicit = flag(argv, "--state-dir")
      return explicit if explicit

      load_config_quietly(flag(argv, "--config"))&.state_dir || DEFAULT_STATE_DIR
    rescue StandardError
      DEFAULT_STATE_DIR
    end

    # argv scanned by hand, because the reason we are here may well be that
    # OptionParser refused to scan it. Both spellings, and nothing clever: a
    # recipient we cannot find is a nil field, not an error on top of an error.
    def flag(argv, name)
      argv.each_with_index do |argument, index|
        return argument.split("=", 2).last if argument.start_with?("#{name}=")
        return argv[index + 1] if argument == name && argv[index + 1]
      end
      nil
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
