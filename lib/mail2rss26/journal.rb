# frozen_string_literal: true

require "fileutils"
require "json"

module Mail2rss26
  # The delivery journal: one line per *run of `ingest`*, appended, never
  # rewritten.
  #
  #   /var/lib/mail2rss26/journal/2026-09.jsonl
  #   /var/lib/mail2rss26/journal/.lock
  #
  # It exists because almost everything this program decides used to leave no
  # trace. A stored message left an .eml and a re-rendered feed, but nothing
  # saying which address matched it or where its date came from; a redelivery
  # left nothing at all, because it is a no-op against the disk by design; an
  # unknown recipient left nothing by promise ("nothing was written"); and a
  # deferral left nothing but a line on stderr, which OpenSMTPD copies into the
  # mail log and which is therefore gone the moment the log rotates. The
  # question "what arrived, and what did we do with it?" had no answer on disk.
  #
  # Still files, still no database: a backup is a copy of a directory, and
  # debugging is `cat` — or `jq`, since every line is a JSON object. One file
  # per month keeps a `cat` sane and makes retention an `rm` rather than a
  # feature.
  #
  # Four rules this class exists to keep:
  #
  #   *A journal failure never fails a delivery.* `record` does not raise —
  #   it reports on stderr and returns nil. This is the one place in this
  #   project where swallowing an error is right, and the reasoning is the
  #   mirror of everywhere else: the convention "a swallowed exception is a
  #   lost newsletter" is about the newsletter. Turning a delivery that already
  #   has its .eml safely on disk into a deferral, because the *note about it*
  #   could not be written, would be the convention applied to the wrong noun.
  #
  #   *One line at a time.* Appends happen under an exclusive flock, so two
  #   simultaneous deliveries cannot interleave halfway through a line. That is
  #   a stronger guarantee than relying on a single small O_APPEND write being
  #   indivisible, and it costs one open() per delivery.
  #
  #   *It is a journal of deliveries, not of runs.* `render` never writes here.
  #   A failed render is a failed systemd unit and shows up as one; a failed
  #   delivery is invisible unless something like this records it.
  #
  #   *It never touches a feed directory.* Nothing under `<state>/<feed>/`
  #   changes, so the renderer sees exactly what it saw before and N6 is not
  #   even in contact with this file.
  class Journal
    # Bumped only if the shape of a line changes incompatibly. Readers skip
    # lines they do not understand rather than failing, so an old file stays
    # readable by a newer viewer for as long as the fields it needs survive.
    SCHEMA_VERSION = 1

    DIR = "journal"
    LOCK = ".lock"

    # Same leading dot, same reason, as Store::LOCK: out of a careless glob.
    FILE_PATTERN = /\A\d{4}-\d{2}\.jsonl\z/

    TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
    TIMESTAMP_PATTERN = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/

    # A subject is attacker-controlled, arrives in any length a bulk mailer
    # feels like, and is here only so a human can recognise a delivery in a
    # list. Truncating keeps a line small enough to stay comfortably readable
    # in `cat` and keeps one absurd newsletter from making a month's file
    # unusable. The whole subject is always still in the .eml.
    TEXT_LIMIT = 200

    # What happened to the envelope. These four strings are the vocabulary the
    # viewer filters on, so they are as much an interface as the exit codes:
    #
    #   stored     the message was written and the feed re-rendered (exit 0)
    #   duplicate  we already had this Message-ID; nothing was written (exit 0)
    #   no-feed    the recipient names no feed; nothing was written (exit 67)
    #   deferred   something failed; the envelope stays in the queue (exit 75)
    OUTCOMES = %w[stored duplicate no-feed deferred].freeze

    # The journal is there but this process may not read it — which on the real
    # machine means `mail2rss26 log` was run without sudo, because the
    # directory is 0750 and owned by the delivery user.
    #
    # It is a distinct error rather than an empty result on purpose, and the
    # reason is the whole point of the journal. "No deliveries recorded" and
    # "you cannot see the deliveries" look identical on a terminal, and the
    # first one is exactly the reassuring answer this feature exists to stop
    # being believed: a delivery agent that has been deferring since Tuesday
    # also produces an empty list. An inspection tool that answers "all quiet"
    # when it means "I cannot tell" is worse than no tool.
    class Unreadable < StandardError; end

    class << self
      def dir(state_dir)
        File.join(state_dir, DIR)
      end

      def timestamp(time)
        time.utc.strftime(TIMESTAMP_FORMAT)
      end

      # Deliberately not Time.iso8601: `time` is not one of the default gems
      # this program's require-audit cleared, and under the packaged wrapper an
      # unaudited require is a LoadError in the middle of a delivery. A journal
      # timestamp is a string we wrote ourselves in a format we fixed, so
      # parsing it is six integers and Time.utc.
      def parse_timestamp(text)
        match = TIMESTAMP_PATTERN.match(text.to_s)
        return nil unless match

        Time.utc(*match.captures.map { |part| Integer(part, 10) })
      rescue ArgumentError
        nil
      end

      def truncate(text)
        text = text.to_s.gsub(/\s+/, " ").strip
        text.length > TEXT_LIMIT ? "#{text[0, TEXT_LIMIT - 1]}…" : text
      end
    end

    attr_reader :dir

    # `stderr` is where a journal failure goes, and the only place it goes.
    def initialize(state_dir, stderr: $stderr)
      @dir = self.class.dir(state_dir)
      @stderr = stderr
    end

    # Appends one line. Answers the recorded hash, or nil if anything at all
    # went wrong — see the class comment for why that is not an exception.
    def record(fields)
      fields = fields.dup
      at = fields.delete(:at) || Time.now.utc

      entry = { "v" => SCHEMA_VERSION, "at" => self.class.timestamp(at) }
      # Ordered, and nils dropped: a line a human reads left to right, and no
      # `"feed": null` for a delivery that never had one.
      fields.each { |key, value| entry[key.to_s] = value unless value.nil? }

      # The month file is chosen by the same instant that is written into the
      # line, not by a second reading of the clock — otherwise a delivery at
      # the very end of a month could be filed under the next one.
      append(at, JSON.generate(entry))
      entry
    rescue StandardError => e
      @stderr.puts "mail2rss26: could not write the delivery journal: #{e.class}: #{e.message}"
      nil
    end

    # Newest first, filtered, at most `limit`. Reads month files from the
    # newest backwards and stops as soon as it has enough, so a viewer showing
    # the last twenty deliveries does not parse a year of them.
    def entries(feed: nil, outcome: nil, since: nil, limit: nil)
      found = []

      files.reverse_each do |path|
        lines(path).reverse_each do |entry|
          next unless matches?(entry, feed: feed, outcome: outcome, since: since)

          found << entry
          return found if limit && found.length >= limit
        end
      end

      found
    end

    # Every month file, oldest first.
    #
    # A *missing* directory is not an error: it means nothing has been
    # delivered yet, which is the state of a machine deployed this morning and
    # the viewer has to render it. Anything else is — see Unreadable.
    def files
      Dir.children(@dir).grep(FILE_PATTERN).sort.map { |name| File.join(@dir, name) }
    rescue Errno::ENOENT
      []
    rescue SystemCallError => e
      raise Unreadable, "cannot read the delivery journal at #{@dir}: #{e.message}"
    end

    private

    def path_for(time)
      File.join(@dir, "#{time.utc.strftime('%Y-%m')}.jsonl")
    end

    def append(at, line)
      FileUtils.mkdir_p(@dir, mode: 0o750)

      File.open(File.join(@dir, LOCK), File::RDWR | File::CREAT, 0o640) do |lock|
        lock.flock(File::LOCK_EX)
        # RDWR and an explicit seek rather than O_APPEND, because the lock is
        # already the thing that serialises writers and this way the tail can
        # be inspected before writing. What that buys is the next line down.
        File.open(path_for(at), File::RDWR | File::CREAT, 0o640, encoding: Encoding::UTF_8) do |file|
          file.write("\n") if torn?(file)
          file.seek(0, IO::SEEK_END)
          file.write("#{line}\n")
        end
      end
    end

    # A file whose last byte is not a newline was left mid-write by a machine
    # that lost power, and appending straight onto it would splice the torn
    # bytes and the new record into one unparseable line — turning one lost
    # delivery into two. Closing the tear costs a seek and a byte, and the
    # damaged line is skipped by the reader on its own.
    def torn?(file)
      file.seek(0, IO::SEEK_END)
      return false if file.pos.zero?

      file.seek(-1, IO::SEEK_END)
      file.read(1) != "\n"
    end

    # Read as UTF-8 explicitly, and never as whatever the locale happens to
    # say. This is not a nicety: a delivery agent runs with no environment at
    # all, so Encoding.default_external is US-ASCII on the server, and the
    # first journal line holding a Polish subject would raise
    # Encoding::CompatibilityError out of the plainest String method. Journal
    # lines are JSON, and JSON is UTF-8 by definition (RFC 8259) — there is no
    # locale question to ask.
    def lines(path)
      File.readlines(path, chomp: true, encoding: Encoding::UTF_8).filter_map { |line| parse(line) }
    rescue Errno::ENOENT
      # Listed a moment ago and gone now: whatever prunes old months won the
      # race, and the months that are still there are still the answer.
      []
    rescue SystemCallError => e
      raise Unreadable, "cannot read #{path}: #{e.message}"
    end

    # A line this reader cannot use is skipped, not fatal. Two ways that
    # happens and both are worth surviving: a future schema version written by
    # a newer binary, and a half-written final line left by a machine that lost
    # power mid-append. Neither is a reason to refuse to show the other
    # thousand deliveries.
    def parse(line)
      # Invalid UTF-8 cannot have come from JSON.generate, so it is a damaged
      # line — the tail of a torn write, most likely — and is skipped with the
      # rest of them. Checking before touching the string matters, because
      # String#strip on invalid bytes raises rather than answering.
      return nil unless line.valid_encoding?
      return nil if line.strip.empty?

      entry = JSON.parse(line)
      entry.is_a?(Hash) && entry["v"] == SCHEMA_VERSION ? entry : nil
    rescue JSON::ParserError
      nil
    end

    def matches?(entry, feed:, outcome:, since:)
      return false if feed && entry["feed"] != feed
      return false if outcome && entry["outcome"] != outcome

      if since
        at = self.class.parse_timestamp(entry["at"])
        return false if at.nil? || at < since
      end

      true
    end
  end
end
