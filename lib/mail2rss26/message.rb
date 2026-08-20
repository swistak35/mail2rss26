# frozen_string_literal: true

require "date"
require "digest"
require "mail"

module Mail2rss26
  # One delivered message, reduced to exactly the things a feed entry is made
  # of: a title, an author, a date, a stable id (F4) and a body (F3).
  #
  # Every reader here is total. For any byte string `mail` accepts it answers
  # something usable, and none of them raise. That is a deliberate line drawn
  # through N3, so it is worth writing down where it runs:
  #
  #   A malformed *message* is not an error. A bulk mailer that omits Subject,
  #   dates its mail on the 32nd of August, sends two Subject headers or
  #   declares us-ascii over raw UTF-8 has not broken this program, and
  #   refusing such a message would not fix it — it would park the newsletter
  #   in the OpenSMTPD queue and retry it forever. An entry titled
  #   "(no subject)" is a strictly better outcome than a message that never
  #   arrives.
  #
  #   A failure of *our* side still is an error and still exits non-zero:
  #   unreadable stdin, an unwritable state directory, bytes that are not a
  #   message at all. Those are the ones the queue can usefully retry, and
  #   nothing in this file catches them.
  class Message
    # TODO 4 of Phase 2, decision one. Subject is optional in RFC 5322 and bulk
    # mailers use that permission; a newsletter without one still has to become
    # an entry. The placeholder is a constant rather than an empty title because
    # F2 wants a feed that reads well in a reader, and readers render an empty
    # <title> as blank space.
    NO_SUBJECT = "(no subject)"

    # From is mandatory in RFC 5322 and still turns up unparseable, at which
    # point `mail` degrades the field to an unstructured string. Same reasoning
    # as above: better a named author than a deferred message.
    NO_AUTHOR = "(unknown sender)"

    # TODO 4 of Phase 2, decision two. A message that does not date itself is
    # dated *from the message*, never from the clock: Time.now here would make
    # the same mailbox render differently on every run and break N6. The order
    # is Date header, then the timestamp our own OpenSMTPD stamped into the
    # topmost Received header (it is part of the stored .eml, so it is as
    # deterministic as the file), then this epoch. An entry dated 1970 sorts to
    # the bottom of a reader and is visibly wrong, which is what we want from a
    # message that told us nothing at all.
    EPOCH = Time.at(0).utc.freeze

    # Last resort for bytes no declared charset explains. Windows-1252 maps
    # almost every byte to something, so this cannot fail and cannot lose the
    # message; it can only make it ugly.
    SALVAGE_CHARSET = Encoding::WINDOWS_1252

    def self.read(path)
      new(Mail.read(path))
    end

    def self.parse(source)
      new(Mail.read_from_string(source))
    end

    attr_reader :mail

    def initialize(mail)
      @mail = mail
    end

    # F4: the entry title.
    def title
      subject = utf8(@mail.subject).strip
      subject.empty? ? NO_SUBJECT : subject
    end

    # F4: the entry author, as a display name — "The Lamplighter", falling back
    # to the bare address, falling back to whatever the From header did say.
    def author
      name = utf8(from_address&.display_name).strip
      return name unless name.empty?
      return author_email if author_email

      raw = utf8(@mail[:from]&.value).strip
      raw.empty? ? NO_AUTHOR : raw
    end

    # nil when From is missing or too broken to hold an address. Atom's
    # <email> is optional; <name> is not, which is why `author` never is.
    def author_email
      from_address&.address
    end

    # F4: the entry date, always UTC, always present. See EPOCH.
    def date
      header_date || received_date || EPOCH
    end

    # The stable half of the Atom entry id and the key F6 dedups on. A message
    # with no Message-ID gets one derived from its own bytes, so redelivering
    # the identical message still collapses to one entry.
    def message_id
      id = utf8(@mail.message_id).strip
      return id unless id.empty?

      "sha256:#{Digest::SHA256.hexdigest(@mail.raw_source.to_s)}"
    end

    # F3: the text/html part, or text/plain when the message has no HTML at
    # all. `mail` walks nested multiparts to find them and skips attachments on
    # the way — a multipart/related inside a multipart/alternative, or an
    # alternative inside a mixed with a text/plain attachment bolted on, both
    # resolve here without this file knowing what a boundary is. That is the
    # entire reason the project spends its one gem on `mail`.
    def body
      part = body_part
      return "" if part.nil?

      utf8(part.body.decoded, part.charset)
    end

    # Phase 3 needs this to pick the Atom content type; it is not a guess about
    # the markup, just which part won.
    def html?
      body_part&.mime_type == "text/html"
    end

    private

    def body_part
      return @body_part if defined?(@body_part)

      @body_part = @mail.html_part || @mail.text_part || own_body_part
    end

    # A single-part message has no parts, so html_part/text_part find nothing
    # and the message is its own body. No Content-Type means text/plain
    # (RFC 2045); anything else single-part is an attachment-only message and
    # has no body we would want to show.
    def own_body_part
      return nil if @mail.multipart?

      type = @mail.mime_type
      type.nil? || %w[text/plain text/html].include?(type) ? @mail : nil
    end

    def from_address
      field = @mail[:from]
      # An unparseable From is an unstructured field: it has a value but no
      # addresses, and asking it for them is a NoMethodError.
      return nil unless field.respond_to?(:addrs)

      field.addrs.first
    end

    def header_date
      to_time(@mail.date)
    end

    def received_date
      received_fields.each do |field|
        time = field_time(field)
        return time if time
      end
      nil
    end

    def received_fields
      fields = @mail[:received]
      fields = [fields] unless fields.is_a?(Array)
      fields.compact
    end

    def field_time(field)
      return nil unless field.respond_to?(:date_time)

      to_time(field.date_time)
    rescue ArgumentError, TypeError
      # A Received header whose trace is fine but whose timestamp is not. The
      # next one down may still be usable.
      nil
    end

    # `mail` answers a DateTime for a Date it understood and nil for one it
    # gave up on — but for a Date it only half-recognised it answers the raw
    # String. Only an actual point in time counts as a date here.
    def to_time(value)
      case value
      when Time then value.utc
      when DateTime then value.to_time.utc
      end
    end

    # Everything that leaves this object is valid UTF-8, because everything
    # downstream (Atom in Phase 3) assumes it. `mail` hands back bytes tagged
    # with whatever the message claimed, and bulk mailers lie — "charset=
    # us-ascii" over an 8-bit UTF-8 body is the classic, and trusting it
    # replaces every Polish letter with U+FFFD. So: believe the declared
    # charset only if the bytes are actually valid in it, then try UTF-8 (which
    # is self-validating enough that a false positive needs deliberate effort),
    # then salvage. No path out of here raises an Encoding error, because an
    # exception mid-ingest is a message deferred in the queue forever.
    def utf8(value, charset = nil)
      return "" if value.nil?

      bytes = value.to_s.dup.force_encoding(Encoding::BINARY)
      text = transcode(bytes, charset) ||
             transcode(bytes, Encoding::UTF_8) ||
             bytes.encode(Encoding::UTF_8, SALVAGE_CHARSET, invalid: :replace, undef: :replace)
      text.scrub
    end

    def transcode(bytes, charset)
      return nil if charset.nil? || charset.to_s.empty?

      text = bytes.dup.force_encoding(Encoding.find(charset.to_s))
      return nil unless text.valid_encoding?

      text.encode(Encoding::UTF_8)
    rescue ArgumentError, EncodingError
      # An unknown charset name, or one Ruby has no converter for. Both are the
      # sender's problem and neither is worth deferring a newsletter over.
      nil
    end
  end
end
