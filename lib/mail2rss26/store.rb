# frozen_string_literal: true

require "digest"
require "fileutils"

module Mail2rss26
  # The state directory, and the only place that knows its shape:
  #
  #   /var/lib/mail2rss26/<feed>/20260812T060316Z-<id>.eml   one delivered message
  #   /var/lib/mail2rss26/<feed>/atom.xml                    what nginx serves
  #   /var/lib/mail2rss26/<feed>/.lock                       one delivery at a time
  #
  # Files, not a database: a backup is a copy of the directory and debugging is
  # `cat`. Everything in here is *state*; the feed list that says which
  # directories may exist is *configuration* and lives in Config.
  #
  # The filename carries two things, and both are load-bearing.
  #
  #   The timestamp is the entry's date as best known at delivery — the
  #   message's own Date (or the Received our OpenSMTPD stamped), and the
  #   delivery clock only for a message that dated itself not at all. It sorts
  #   the directory chronologically for a human with `ls`, and it is read back
  #   at render time as Message's fallback date, which is how a dateless
  #   newsletter escapes 1970 without anything ever calling Time.now during a
  #   render (N6). See CLI#ingest for why taking the clock *once*, at delivery,
  #   is not the same thing as rendering from the clock.
  #
  #   The id is the Message-ID, sanitised (below) and therefore stable per
  #   message. That is F6 moved one step earlier than Phase 3's render-time
  #   dedup: the same newsletter delivered twice does not merely collapse into
  #   one entry, it does not write a second file at all.
  class Store
    ATOM = "atom.xml"

    # Not "lock" and not "mail2rss26.lock": the leading dot keeps it out of a
    # careless `nginx autoindex` and out of any glob a human types, and the
    # renderer only ever looks at *.eml anyway.
    LOCK = ".lock"

    # ISO 8601 basic form, always UTC. No colons (they are legal on ext4 and a
    # nuisance everywhere else, scp included) and no separators inside the date,
    # so a plain lexicographic sort of the directory is a chronological one —
    # which is exactly the sort Feed.from_directory does for N6.
    TIMESTAMP_FORMAT = "%Y%m%dT%H%M%SZ"
    TIMESTAMP_PATTERN = /\A(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z-/

    # A Message-ID is nearly free-form: RFC 5322 allows a quoted string on the
    # left of the @, and mailers that ignore even that put spaces, slashes and
    # UTF-8 in there. None of that may reach a path. Everything outside this set
    # becomes "-", which is safe but *not injective* — two different ids could
    # sanitise to the same slug and the second message would look like a
    # redelivery of the first and be dropped. So the slug is only for human
    # eyes, and the identity comes from the digest appended after it.
    ID_UNSAFE = /[^A-Za-z0-9.@_-]/

    # Enough slug to recognise a message in `ls`, not enough to threaten
    # NAME_MAX (255) once the timestamp, the digest and ".eml" are added.
    ID_SLUG_LIMIT = 40

    # 64 bits of SHA-256 over the *original* Message-ID. Two distinct ids
    # colliding here is far less likely than the filesystem lying to us, and
    # unlike a truncated slug it cannot be engineered by a sender who can only
    # choose their own Message-ID.
    ID_DIGEST_LENGTH = 16

    class << self
      def filename(time, message_id)
        "#{time.utc.strftime(TIMESTAMP_FORMAT)}#{suffix(message_id)}"
      end

      # The half of the filename that identifies the message rather than when
      # it turned up. Delivery matches on this suffix, so the two can never
      # drift apart.
      def suffix(message_id)
        "-#{file_id(message_id)}.eml"
      end

      def file_id(message_id)
        # Runs of "." collapse along with runs of "-": traversal is already
        # impossible (the name is one path component, and it starts with the
        # timestamp), but a filename containing ".." is the kind of thing that
        # makes a reviewer stop and check, and it buys nothing.
        slug = message_id.to_s.gsub(ID_UNSAFE, "-").squeeze("-.")[0, ID_SLUG_LIMIT].to_s
        # A slug that is all separators, or empty because the Message-ID was,
        # would leave a name starting or ending in a separator. Ugly rather
        # than dangerous, and cheap to not have.
        slug = slug.gsub(/\A[-.]+|[-.]+\z/, "")
        digest = Digest::SHA256.hexdigest(message_id.to_s)[0, ID_DIGEST_LENGTH]

        slug.empty? ? digest : "#{slug}-#{digest}"
      end

      # The fallback date Phase 2 left to this phase: the delivery timestamp
      # this program itself wrote into the name. nil for anything that does not
      # look like one of our files (a hand-copied .eml, a name from an older
      # convention) — the caller then gets Message's epoch, exactly as before.
      def timestamp_of(name)
        match = TIMESTAMP_PATTERN.match(name)
        return nil unless match

        time = Time.utc(*match.captures.map { |part| Integer(part, 10) })
        # Time.utc rolls the 31st of February over into March instead of
        # objecting, so the only way to know the name held a real date is to
        # write it back out and compare. A syntactically fine name that is not
        # a date has no timestamp, and the epoch is a defined answer for it.
        time.strftime(TIMESTAMP_FORMAT) == match[0].delete_suffix("-") ? time : nil
      rescue ArgumentError
        # The rollover Time.utc does *not* tolerate: a thirteenth month.
        nil
      end

      def atom_path(dir)
        File.join(dir, ATOM)
      end

      # N4, for both files this program writes: the rename is the atomic step
      # and it is only atomic within one filesystem, so the temporary file is a
      # sibling of the target rather than something under /tmp. fsync before the
      # rename because rename orders the directory entry and not the data behind
      # it: without it a crash can leave a correctly named file full of zeroes,
      # which is exactly the half-written feed N4 exists to prevent. The
      # directory is synced after, so the rename itself survives the same crash.
      #
      # The temporary name carries the pid because OpenSMTPD may well run two
      # deliveries at once, and a shared scratch file would let them interleave
      # into one corrupt document before either got as far as renaming.
      def write_atomically(path, content)
        tmp = "#{path}.#{Process.pid}.tmp"
        begin
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o644) do |file|
            # The .eml is stored byte for byte as it arrived — Phase 2's
            # charset guessing happens on the way *out*, never on the way in.
            file.binmode
            file.write(content)
            file.flush
            file.fsync
          end
          File.rename(tmp, path)
          File.open(File.dirname(path)) { |dir| dir.fsync }
        ensure
          # Only reached when something above raised; after a successful rename
          # there is nothing at this name any more. The exception itself is not
          # touched — a file we failed to write is our side failing, and N3
          # wants it loud and non-zero.
          File.unlink(tmp) if File.exist?(tmp)
        end
        path
      end
    end

    attr_reader :root

    def initialize(root)
      @root = root
    end

    def feed_dir(feed)
      File.join(@root, feed.name)
    end

    # Everything one delivery (or one render) does to one feed, with the
    # directory created if it is missing and an exclusive lock held throughout.
    #
    # The lock is not paranoia about the *writes* — those are atomic already —
    # but about the gap between them. Two concurrent deliveries could otherwise
    # both list the directory before either had written its .eml, and the render
    # that renamed last would publish a feed missing the other's entry until
    # some later delivery happened to fix it. flock is released by the kernel
    # when the process dies, so a crashed delivery cannot wedge a feed.
    #
    # Creating the directory is deliberate: the feed exists because it is in the
    # configuration, so its directory is ours to make. It also means `render` on
    # a brand-new feed publishes a valid empty document instead of a 404.
    def with_feed(feed)
      dir = feed_dir(feed)
      FileUtils.mkdir_p(dir)

      File.open(File.join(dir, LOCK), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield dir
      end
    end

    # F6 at delivery time. Answers the path written, or nil when this message is
    # already on disk under some other timestamp — a redelivery is then a no-op
    # against the disk, not merely something the renderer folds away.
    #
    # The match is on the id suffix rather than the whole name because the
    # timestamp may differ between deliveries: a message with no date of its own
    # is filed under the delivery clock, and the second delivery's clock reads
    # later than the first's.
    def store(dir, time, message_id, raw)
      return nil if find(dir, message_id)

      self.class.write_atomically(
        File.join(dir, "#{time.utc.strftime(TIMESTAMP_FORMAT)}#{self.class.suffix(message_id)}"), raw
      )
    end

    # The name this message is already filed under, or nil. Split out of
    # `store` because a redelivery is now worth *naming* as well as skipping:
    # the delivery journal says which file the message we already had is in,
    # which is the difference between "nothing happened" and "we have this one
    # already, here it is".
    def find(dir, message_id)
      suffix = self.class.suffix(message_id)
      Dir.children(dir).find { |name| name.end_with?(suffix) }
    end
  end
end
