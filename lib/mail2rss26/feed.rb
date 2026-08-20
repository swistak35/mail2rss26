# frozen_string_literal: true

require "mail2rss26/message"
require "mail2rss26/store"

module Mail2rss26
  # A directory of .eml files, rendered to one Atom document (F2) and written
  # to disk without a reader ever seeing half of it (N4).
  #
  # No XML library. REXML would be the obvious stdlib candidate and it is not
  # one: since Ruby 3.0 it is a *bundled* gem, not a default one, so it lives in
  # the interpreter's gem directory rather than its stdlib and is only visible
  # when GEM_PATH happens to include that directory. Phase 1 already met this
  # trap once (bundlerEnv sets GEM_PATH to the packaged gems and nothing else,
  # which is why the test derivation names the interpreter's directory by hand),
  # and the plan says the Phase 5 wrapper will meet it again. A `require` that
  # works in the dev shell and raises LoadError on the server, mid-delivery, is
  # a bad way to find that out. Checked, not assumed:
  #
  #   $ GEM_PATH=<only the bundlerEnv dir> ruby -rrexml/document -e ''
  #   cannot load such file -- rexml/document
  #
  # The other half of the reason is that the plan budgets "a dozen-odd lines"
  # for this and a serialiser we control is the one that can promise N6 byte
  # for byte. What we owe in exchange is correct escaping, which is the two
  # methods at the bottom of this file and nothing else — no DOM, no pretty
  # printer deciding where to put whitespace this week.
  class Feed
    # F7. Fifty is the plan's answer ([2026-08-20 czw], not up for renegotiation
    # until it hurts); what matters here is that it has a name, because a bare
    # 50 in a `take` is the kind of thing nobody finds when it does start to
    # hurt. Retention is applied at render time only: the .eml files stay on
    # disk, so raising this number republishes the older entries rather than
    # needing them re-delivered.
    MAX_ENTRIES = 50

    # The empty feed still needs an <updated>, and it may not come from the
    # clock — see Message::EPOCH for the same argument at the entry level.
    EPOCH = Message::EPOCH

    # Atom dates are RFC 3339 (xs:dateTime), *not* the RFC 2822 form the mail
    # headers use. One fixed UTC spelling, so the same instant always
    # serialises to the same bytes (N6).
    RFC3339 = "%Y-%m-%dT%H:%M:%SZ"

    # XML 1.0 forbids most C0 control bytes outright — they cannot even be
    # escaped as character references — and real newsletters contain them
    # (stray form feeds, a NUL left by a broken template engine). One of them
    # anywhere in the body makes the whole feed unparseable, which is F2 gone
    # for every entry at once. Dropping them is *not* the sanitising the plan
    # ruled out: it removes nothing a reader would have rendered, and the
    # markup is passed through exactly as it arrived.
    #
    # The permitted set is Char from the XML 1.0 grammar: tab, LF, CR and
    # everything from U+0020 up, minus the surrogate block (which valid UTF-8
    # cannot hold anyway) and the two non-characters U+FFFE and U+FFFF.
    ILLEGAL_XML = /[^\u{9}\u{A}\u{D}\u{20}-\u{D7FF}\u{E000}-\u{FFFD}\u{10000}-\u{10FFFF}]/

    # Everything outside this set gets percent-encoded on the way into an entry
    # id. Unreserved characters per RFC 3986 plus "@", which is what actually
    # separates the two halves of a Message-ID and is legal in a path.
    ID_UNSAFE = /[^A-Za-z0-9\-._~@]/

    attr_reader :id, :title, :self_url, :messages

    # `id` and `title` are the feed's identity and both are mandatory in Atom.
    # They are arguments rather than something this class invents, and that is
    # F8 showing up in a signature: the feed's identity is a token chosen with
    # the feed (in Nix, from Phase 7), and it must not be derivable from the
    # address the newsletter was delivered to. Nothing in this file ever reads
    # To, Delivered-To or Received, so the incoming address cannot leak into
    # the document by accident either.
    #
    # `self_url` is optional for the same reason: it is the unguessable URL, so
    # a caller that does not want it written into the file it serves can leave
    # it out and still get a valid feed.
    def initialize(id:, title:, messages: [], self_url: nil)
      @id = id
      @title = title
      @self_url = self_url
      @messages = messages
    end

    # Every .eml in one feed's directory. Dir.glob's order is unspecified —
    # it is whatever readdir hands back, which on ext4 is hash order and on a
    # restored backup is a different hash order — so it is sorted here and the
    # rest of this class can rely on a fixed input sequence (N6).
    #
    # Dir.children raises on a missing directory rather than answering "no
    # messages". That is N3: an absent feed directory is our side being wrong,
    # not a newsletter being ugly, and it must not render an empty feed over a
    # feed that was fine yesterday.
    #
    # Each message is given the timestamp out of its own filename as a fallback
    # date. Phase 2 left a message with neither a Date nor a Received header
    # sitting in 1970, visibly wrong and at the bottom of every reader; the
    # delivery timestamp `ingest` wrote into the name is strictly better and
    # costs nothing, because it is *state on disk* — read from the same bytes
    # every render, so N6 is untouched. Nothing here ever asks the clock.
    def self.from_directory(dir, id:, title:, self_url: nil)
      names = Dir.children(dir).grep(/\.eml\z/).sort

      messages = names.map do |name|
        Message.read(File.join(dir, name), fallback_date: Store.timestamp_of(name))
      end

      new(id: id, title: title, self_url: self_url, messages: messages)
    end

    # The messages that actually become entries: deduplicated (F6), newest
    # first, capped (F7).
    def entries
      @entries ||= sort_messages(deduplicate(@messages)).first(MAX_ENTRIES)
    end

    # The feed's own timestamp is the newest entry's, never Time.now — with the
    # clock in here N6 would be false by construction, and a feed whose only
    # change on every render is <updated> teaches readers to re-poll it for
    # nothing. An empty feed falls back to the epoch, for the same reason a
    # dateless message does.
    def updated
      entries.map(&:date).max || EPOCH
    end

    def to_atom
      xml = +%(<?xml version="1.0" encoding="utf-8"?>\n)
      xml << %(<feed xmlns="http://www.w3.org/2005/Atom">\n)
      xml << element("id", @id)
      xml << element("title", @title)
      xml << element("updated", updated.utc.strftime(RFC3339))
      # rel="self" is the feed telling a reader where it lives; RFC 4287 only
      # recommends it, but a feed without one is what makes validators grumble.
      xml << %(  <link rel="self" type="application/atom+xml" href="#{attribute(@self_url)}"/>\n) if @self_url
      # No uri= attribute: it is optional, this repository has no public home,
      # and a URL invented here would be a lie a reader could click. The version
      # is the constant from lib/mail2rss26.rb and never anything the build
      # environment supplies — a hostname or a build date in here would break
      # N6 the first time the feed was rendered on another machine.
      xml << %(  <generator version="#{attribute(VERSION)}">mail2rss26</generator>\n)
      entries.each { |message| xml << entry(message) }
      xml << "</feed>\n"
      xml
    end

    # N4, and it moved: the write-then-rename dance lives in Store, because
    # Phase 4 does it to the stored .eml as well and one copy of that reasoning
    # (and of the fsync it is easy to leave out) is the right number. Nothing
    # about the guarantee changed — see Store.write_atomically.
    def write(path)
      Store.write_atomically(path, to_atom)
    end

    private

    # F6. The same newsletter delivered twice is one entry, keyed on
    # Message-ID — including the synthetic sha256: form, so a message that
    # never had one still collapses. The first file wins, and "first" is
    # meaningful because from_directory sorted the paths.
    def deduplicate(messages)
      messages.uniq(&:message_id)
    end

    # A total order, which is the part that is easy to get wrong. Date alone is
    # not one: the epoch fallback makes ties likely (every message with neither
    # a Date nor a Received header lands on the same instant), and Ruby's sort
    # is not stable, so a tie would let two runs over the same directory emit
    # the entries in different orders and break N6. Message-ID breaks the tie —
    # it is unique after deduplication, so the order is total.
    def sort_messages(messages)
      messages.sort do |a, b|
        by_date = b.date <=> a.date
        by_date.zero? ? a.message_id <=> b.message_id : by_date
      end
    end

    def entry(message)
      xml = +"  <entry>\n"
      xml << element("id", entry_id(message), indent: "    ")
      xml << element("title", message.title, indent: "    ")
      xml << element("updated", message.date.utc.strftime(RFC3339), indent: "    ")
      # Identical to <updated> because we only ever see a message once; readers
      # sort on <published> and would otherwise have to guess.
      xml << element("published", message.date.utc.strftime(RFC3339), indent: "    ")
      xml << author(message)
      # F3 chose the part; html? says which of the two type values it was. The
      # markup is escaped, never cleaned — the plan settled that readers
      # sanitise anyway and doing it here is a dependency plus a way to mangle
      # content. An attachment-only message has an empty body and gets an empty
      # <content>: RFC 4287 lets an entry with no content stand only if it has
      # a rel="alternate" link, and it has nowhere to point.
      xml << element("content", message.body, indent: "    ",
                                              attributes: %( type="#{message.html? ? "html" : "text"}"))
      xml << "  </entry>\n"
      xml
    end

    # <name> is mandatory in Atom, which is why Message#author never answers
    # nil. <email> is optional, and it is only written when it looks like an
    # address at all: Atom's own type says ".+@.+", and a From header broken
    # enough to yield something else would make the document invalid for the
    # sake of a field nobody reads.
    def author(message)
      xml = +"    <author>\n"
      xml << element("name", message.author, indent: "      ")
      email = message.author_email
      xml << element("email", email, indent: "      ") if email&.match?(/.+@.+/)
      xml << "    </author>\n"
      xml
    end

    # F4's Message-ID has to become an Atom id, and an Atom id is an IRI, which
    # a bare Message-ID is not. Two shapes, because there are two kinds of
    # value and pretending otherwise would mean lying in one of them:
    #
    #   a real Message-ID -> mid:20260812060316.4c1b9a7e@mail.example
    #     RFC 2392 registered "mid" scheme, which is exactly this: a URI naming
    #     a message by its Message-ID. Readable in a debug session, and it
    #     round-trips.
    #   Message's sha256: fallback -> urn:sha256:<hex>
    #     Not a registered URN namespace, but syntactically a valid URN and an
    #     honest description of what the value is. mid: here would claim the
    #     message had a Message-ID when the whole point is that it did not.
    #
    # Deliberately *not* derived from the feed's id: F8 makes that id a secret
    # token, and a rotated secret must not silently turn every entry into a new
    # one and re-notify the reader about a year of newsletters.
    #
    # Everything outside the unreserved set is percent-encoded, so a sender
    # putting a space, a bracket or a Cyrillic letter in its Message-ID (they
    # do) cannot produce an id that is not a URI.
    def entry_id(message)
      id = message.message_id
      return "urn:sha256:#{percent_encode(id.delete_prefix("sha256:"))}" if id.start_with?("sha256:")

      # The angle brackets are not part of the identifier; `mail` strips them,
      # but a Message-ID mangled enough to keep one would otherwise smuggle a
      # %3C into the id forever.
      "mid:#{percent_encode(id.delete_prefix("<").delete_suffix(">"))}"
    end

    def percent_encode(text)
      # Byte-wise on purpose: percent-encoding is defined over octets, so a
      # multi-byte character becomes several escapes rather than one broken
      # one. The result is pure ASCII, hence safe to label UTF-8 again.
      text.dup.force_encoding(Encoding::BINARY)
          .gsub(ID_UNSAFE) { |byte| format("%%%02X", byte.ord) }
          .force_encoding(Encoding::UTF_8)
    end

    def element(name, text, indent: "  ", attributes: "")
      "#{indent}<#{name}#{attributes}>#{escape(text)}</#{name}>\n"
    end

    # Character data. ">" needs escaping only inside "]]>", but escaping it
    # always is one branch fewer and no reader can tell the difference.
    def escape(text)
      clean(text).gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
    end

    # Attribute values, which additionally may not contain the quote they are
    # delimited by. Everything written into one here is ours or configuration,
    # never message content, but an unescaped attribute is the kind of thing
    # that stays wrong until the day it is exploited.
    def attribute(text)
      escape(text).gsub('"', "&quot;")
    end

    def clean(text)
      # scrub first: the regex below raises on bytes that are not valid UTF-8,
      # and while Message guarantees valid UTF-8 for everything it hands out,
      # the feed's title and id come from configuration and have made no such
      # promise.
      #
      # The line endings are normalised because XML normalises them anyway:
      # every parser turns a literal CRLF or a lone CR into LF before the
      # reader ever sees it (XML 1.0, 2.11). Mail bodies are CRLF throughout,
      # so doing it here rather than leaving it to the parser means the file on
      # disk says what the reader will actually get — and the alternative,
      # writing "&#13;" at the end of every line of every HTML newsletter,
      # doubles the size of the feed to preserve a difference nothing renders.
      text.to_s.scrub.gsub(/\r\n?/, "\n").gsub(ILLEGAL_XML, "")
    end
  end
end
