# frozen_string_literal: true

require "json"

require "mail2rss26/config"
require "mail2rss26/journal"
require "mail2rss26/message"
require "mail2rss26/store"

module Mail2rss26
  # `log`, `show` and `feeds`: the operator's window onto what has been
  # delivered and what was done with it.
  #
  # These are *not* part of the OpenSMTPD contract. Nothing here is ever run by
  # a mail system, nothing here writes anything, and the exit codes are the
  # ordinary shell ones rather than the three the delivery path is allowed —
  # see CLI::EX_FAILURE. Keeping them in their own file is the same line: cli.rb
  # is the interface with smtpd, this is the interface with a person at a
  # terminal, and the two have almost nothing to say to each other.
  #
  # It reads the journal, the stored .eml files and the rendered atom.xml, and
  # that is all. No daemon and no port (N1 was never in danger, but it is worth
  # saying: a web UI is what this project decided not to have, and a terminal
  # on the machine is the whole of the requirement).
  class Viewer
    # `ls`-ish rather than ISO: this output is read by a human, and the T and
    # the Z that make a timestamp sortable make it harder to scan. --json
    # answers with what the journal actually holds.
    DISPLAY_FORMAT = "%Y-%m-%d %H:%M:%S"

    # Terminal width, and why it is read from the environment rather than from
    # an ioctl: `mail2rss26 log` run under sudo, over ssh, in a pipe or from a
    # test has no terminal at all half the time, and a table whose width
    # depends on whether it is being piped is a table that cannot be diffed.
    # COLUMNS is what the shell exports and what a test can set.
    DEFAULT_WIDTH = 100
    MIN_WIDTH = 60

    # An .eml is a whole newsletter; `show` prints its metadata, not its
    # megabyte of HTML. --raw and --body are the ways to ask for the rest.
    BODY_PREVIEW = 400

    # The journal is 0750 and owned by the delivery user, so the overwhelmingly
    # likely reason it cannot be read is a missing sudo rather than anything
    # broken. Saying which sudo is the difference between an error and an
    # instruction.
    SUDO_HINT = "the journal is readable only by the mail2rss26 user; " \
                "run this as `sudo -u mail2rss26 mail2rss26 ...` (or as root)"

    def initialize(state_dir:, config: nil, stdout: $stdout, stderr: $stderr)
      @state_dir = state_dir
      @config = config
      @stdout = stdout
      @stderr = stderr
      @journal = Journal.new(state_dir, stderr: stderr)
    end

    # One line per run of `ingest`, newest first. The deferrals are the point
    # as much as the deliveries: a silently deferring mda line looks exactly
    # like a quiet week with no newsletters, and this is where the difference
    # becomes visible.
    def log(feed: nil, outcome: nil, since: nil, limit: 50, json: false)
      entries = @journal.entries(feed: feed, outcome: outcome, since: since, limit: limit)

      if json
        entries.each { |entry| @stdout.puts JSON.generate(entry) }
        return
      end

      if entries.empty?
        @stderr.puts "mail2rss26: no deliveries recorded in #{@journal.dir}"
        return
      end

      table(entries)
    end

    # Everything known about one delivery: the journal's account of what was
    # decided, and the message itself if it is still on disk.
    def show(key, part: :summary)
      # `show` degrades rather than failing when the journal is out of reach:
      # the .eml files are world-readable, so most of the answer is still
      # available and printing it beats refusing. What it must not do is
      # present the degraded answer as the complete one — see summary.
      entry = find_entry(key)
      path = message_path(entry, key)

      if entry.nil? && path.nil?
        @stderr.puts "mail2rss26: no delivery matching #{key.inspect} in the journal or on disk"
        return false
      end

      # --raw, --headers and --body all need the message itself, and a refused
      # or deferred delivery has a journal line and nothing else. Saying so and
      # exiting non-zero beats writing nothing and claiming success, because
      # the usual caller is a shell redirect.
      return require_file(path, key) if %i[raw headers body].include?(part) && path.nil?

      case part
      when :raw then @stdout.write(File.binread(path))
      when :headers then headers(path)
      when :body then body(path)
      else summary(entry, path)
      end

      true
    end

    # One row per configured feed: how much is on disk, how much of it a reader
    # actually sees, and when it last received anything. The two counts differ
    # on purpose — F7 truncates the feed at render time and keeps every .eml —
    # so a feed where they diverge is a feed with archive older than its
    # subscribers can see, which is the intended design and nice to be able to
    # confirm.
    def feeds
      return @stderr.puts("mail2rss26: no feed list loaded") if @config.nil?
      return @stderr.puts("mail2rss26: no feeds are configured in #{@config.path}") if @config.feeds.empty?

      print_rows(["FEED", "MESSAGES", "ENTRIES", "LAST DELIVERY", "ADDRESSES"],
                 @config.feeds.map { |feed| feed_row(feed) },
                 align_right: [1, 2], last_flexible: true)

      return unless @unreadable

      @stderr.puts "mail2rss26: #{@unreadable.message}"
      @stderr.puts "mail2rss26: #{SUDO_HINT} — until then \"?\" is \"cannot tell\", not \"never\""
    end

    private

    def width
      value = Integer(ENV["COLUMNS"].to_s, exception: false) || DEFAULT_WIDTH
      value < MIN_WIDTH ? MIN_WIDTH : value
    end

    def table(entries)
      rows = entries.map do |entry|
        [display_time(entry["at"]),
         entry["outcome"].to_s,
         entry["feed"] || "-",
         entry["from"] || "-",
         detail(entry)]
      end

      print_rows(%w[TIME OUTCOME FEED FROM SUBJECT], rows, last_flexible: true)
    end

    # The last column says what a person wants to know about *this* outcome,
    # which is a different thing per outcome: a delivered newsletter is its
    # subject, a refused one is the address nobody owns, and a deferred one is
    # the reason it will be tried again.
    def detail(entry)
      case entry["outcome"]
      when "no-feed" then entry["subject"] || "no feed for #{entry['recipient']}"
      when "deferred" then [entry["reason"], entry["error"]].compact.join(": ")
      else entry["subject"].to_s
      end
    end

    def summary(entry, path)
      message = path && read_message(path)

      pairs = []
      pairs << ["outcome", outcome_line(entry)] if entry
      pairs << ["recipient", recipient_line(entry)] if entry&.dig("recipient")
      pairs << ["feed", entry["feed"]] if entry&.dig("feed")
      pairs << ["message-id", (entry && entry["message_id"]) || message&.message_id]
      pairs << ["file", path]
      pairs << ["size", "#{File.size(path)} bytes"] if path
      pairs << ["from", from_line(entry, message)]
      pairs << ["subject", (message&.title) || entry&.dig("subject")]
      pairs << ["date", date_line(entry, message)]
      pairs << ["body", body_line(entry, message)]
      pairs << ["reason", [entry["reason"], entry["error"]].compact.join(": ")] if entry&.dig("reason")

      if entry
        @stdout.puts "Delivery #{display_time(entry['at'])}"
      elsif @unreadable
        # The distinction matters: "there is no journal line for this" and "I
        # could not look" are different answers, and only one of them means the
        # message predates the journal.
        @stderr.puts "mail2rss26: #{@unreadable.message}"
        @stderr.puts "mail2rss26: #{SUDO_HINT}"
        @stdout.puts "Message on disk; the journal was not readable, so what was done with it is unknown"
      else
        @stdout.puts "Message on disk, no journal entry (delivered before the journal existed)"
      end
      pairs.reject { |_, value| value.nil? || value.to_s.empty? }
           .each { |name, value| @stdout.puts format("  %-11s %s", name, value) }

      preview(message) if message
    end

    def outcome_line(entry)
      exit_code = entry["exit"]
      exit_code ? "#{entry['outcome']} (exit #{exit_code})" : entry["outcome"]
    end

    def recipient_line(entry)
      case entry["match"]
      when "exact" then "#{entry['recipient']} (matched exactly)"
      when "tag" then "#{entry['recipient']} (matched after stripping its +tag)"
      else entry["recipient"]
      end
    end

    def from_line(entry, message)
      return entry["from"] if message.nil?

      email = message.author_email
      email && email != message.author ? "#{message.author} <#{email}>" : message.author
    end

    # Where the entry's date came from is the most common thing to wonder about
    # a newsletter that sorted itself somewhere surprising in a reader, and it
    # is invisible in the .eml — "no Date header, so we used the Received our
    # own smtpd stamped" is a fact about our parser, not about the message.
    def date_line(entry, message)
      time = message ? message.date : Journal.parse_timestamp(entry&.dig("date"))
      return nil if time.nil?

      source = (message ? message.date_source : entry&.dig("date_source"))
      "#{time.strftime(DISPLAY_FORMAT)}Z#{source ? " (#{date_source_english(source)})" : ''}"
    end

    def date_source_english(source)
      case source
      when "header" then "from the message's own Date header"
      when "received" then "no usable Date; from the Received our smtpd stamped"
      when "delivery" then "no date in the message at all; from the delivery clock"
      when "epoch" then "nothing to date it by; the epoch"
      else source
      end
    end

    def body_line(entry, message)
      return entry&.dig("body") if message.nil?

      body = message.body
      return "empty (an attachment-only message renders as an empty entry)" if body.empty?

      "#{message.html? ? 'text/html' : 'text/plain'}, #{body.length} characters"
    end

    def preview(message)
      body = message.body
      return if body.empty?

      @stdout.puts
      @stdout.puts body.length > BODY_PREVIEW ? "#{body[0, BODY_PREVIEW]}…" : body
    end

    def headers(path)
      # Header block only: everything up to the first empty line, which is what
      # RFC 5322 says separates them from the body. Printed raw, because the
      # point of asking for headers is to see what actually arrived — decoded
      # and prettified headers are what the rest of `show` already gives.
      # Binary, for the same reason the journal is read as UTF-8 and for the
      # opposite conclusion: a header block is *not* necessarily any encoding
      # at all — RFC 5322 says ASCII, mailers send raw 8-bit anyway, and the
      # whole point of asking for headers is to see the bytes that arrived. So
      # they are passed through untouched rather than decoded, and nothing here
      # may depend on the locale.
      File.foreach(path, encoding: Encoding::BINARY) do |line|
        break if line.strip.empty?

        @stdout.write(line)
      end
    end

    def body(path)
      @stdout.puts read_message(path).body
    end

    # Always answers false; it exists to put the explanation next to the
    # decision rather than at the call site.
    def require_file(_path, key)
      @stderr.puts "mail2rss26: #{key.inspect} is in the journal but its message is not on disk " \
                   "(a refused or deferred delivery stores nothing)"
      false
    end

    def read_message(path)
      Message.read(path, fallback_date: Store.timestamp_of(File.basename(path)))
    end

    # Newest match wins: a deferred delivery that later succeeded has two lines
    # and the interesting one is the outcome it ended up with.
    def find_entry(key)
      @journal.entries.find do |entry|
        entry["message_id"].to_s.include?(key) || entry["file"].to_s.include?(key)
      end
    rescue Journal::Unreadable => e
      @unreadable = e
      nil
    end

    # The journal knows where a message was filed; anything delivered before
    # the journal existed does not have a line at all, so the feed directories
    # are searched as well. That fallback is not a nicety — on the day this
    # ships, every message on the machine predates the journal.
    def message_path(entry, key)
      if entry && entry["feed"] && entry["file"]
        path = File.join(@state_dir, entry["feed"], entry["file"])
        return path if File.file?(path)
      end

      search_disk(key)
    end

    def search_disk(key)
      feed_dirs.each do |dir|
        name = Dir.children(dir).grep(/\.eml\z/).sort.reverse
                  .find { |candidate| candidate == key || candidate.start_with?(key) || candidate.include?(key) }
        return File.join(dir, name) if name
      end
      nil
    rescue SystemCallError
      nil
    end

    def feed_dirs
      names = @config ? @config.feeds.map(&:name) : Dir.children(@state_dir).reject { |n| n == Journal::DIR }
      names.map { |name| File.join(@state_dir, name) }.select { |dir| File.directory?(dir) }
    rescue SystemCallError
      []
    end

    def feed_row(feed)
      dir = File.join(@state_dir, feed.name)

      [feed.name,
       stored_count(dir).to_s,
       entry_count(File.join(dir, Store::ATOM)).to_s,
       last_delivery(feed),
       feed.addresses.join(", ")]
    end

    # "-" means nothing has ever been delivered; "?" means this process cannot
    # see the journal. Everything else in this table comes from world-readable
    # files, so the command stays useful without sudo — but the one column that
    # would be a guess says so instead of guessing.
    def last_delivery(feed)
      last = @journal.entries(feed: feed.name, outcome: "stored", limit: 1).first
      last ? display_time(last["at"]) : "-"
    rescue Journal::Unreadable => e
      @unreadable ||= e
      "?"
    end

    def stored_count(dir)
      Dir.children(dir).grep(/\.eml\z/).length
    rescue SystemCallError
      0
    end

    # Counted by looking for the line rather than by parsing: rexml is a
    # *bundled* gem and raises LoadError under the packaged wrapper, which is
    # exactly the trap Phase 3 and Phase 5 both walked into. The document is
    # ours, every entry opens with the same two-space-indented line, and the
    # content in between is escaped, so a `<entry>` cannot occur inside one.
    def entry_count(path)
      File.foreach(path, encoding: Encoding::BINARY).count { |line| line.chomp == "  <entry>" }
    rescue SystemCallError
      0
    end

    def display_time(text)
      time = Journal.parse_timestamp(text)
      time ? time.strftime(DISPLAY_FORMAT) : text.to_s
    end

    # Fixed columns sized to their content, with the last one taking whatever
    # the terminal has left. Nothing here wraps: a log you can grep is worth
    # more than a log that never elides anything.
    def print_rows(headings, rows, align_right: [], last_flexible: false)
      widths = headings.each_index.map do |column|
        ([headings[column]] + rows.map { |row| row[column].to_s }).map(&:length).max
      end

      if last_flexible
        used = widths[0..-2].sum + (2 * (widths.length - 1))
        widths[-1] = [width - used, 8].max
      end

      @stdout.puts row_text(headings, widths, align_right)
      rows.each { |row| @stdout.puts row_text(row, widths, align_right) }
    end

    def row_text(row, widths, align_right)
      cells = row.each_with_index.map do |value, column|
        text = value.to_s
        text = "#{text[0, widths[column] - 1]}…" if text.length > widths[column]
        align_right.include?(column) ? text.rjust(widths[column]) : text.ljust(widths[column])
      end
      cells.join("  ").rstrip
    end
  end
end
