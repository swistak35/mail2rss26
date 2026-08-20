# frozen_string_literal: true

require_relative "test_helper"
require "mail"

# Phase 2: .eml in, the fields of one feed entry out (F3, F4).
#
# Every fixture in test/fixtures/ is here to prove exactly one thing that a
# naive parser gets wrong, and every test names which thing. If a fixture ever
# stops being the only justification for some assertion, it should go.
class MessageTest < Minitest::Test
  # --- simple-multipart.eml: the ordinary case ------------------------------
  # A plain multipart/alternative. The one that has to keep working while the
  # rest of this file worries about the ones that do not.

  def test_ordinary_alternative_yields_the_whole_f4_field_set
    m = parsed_fixture("simple-multipart.eml")

    assert_equal "Issue 42: The quiet parts of a slow web", m.title
    assert_equal "The Lamplighter", m.author
    assert_equal "newsletter@lamplighter.example", m.author_email
    assert_equal Time.utc(2026, 8, 12, 6, 3, 16), m.date
    assert_equal "20260812060316.4c1b9a7e@mail.lamplighter.example", m.message_id
  end

  def test_ordinary_alternative_prefers_the_html_part
    m = parsed_fixture("simple-multipart.eml")

    assert m.html?
    assert_includes m.body, "<h1 style="
    # F3 is a choice, not a merge: the plain alternative must not leak in.
    refute_includes m.body, "THE LAMPLIGHTER — ISSUE 42"
  end

  # --- nested-related.eml ---------------------------------------------------
  # multipart/alternative { text/plain, multipart/related { text/html, png } }.
  # The shape the plan names as the one that breaks hand-rolled boundary
  # splitting: the HTML is two levels down and the top-level alternative has no
  # text/html child at all.

  def test_html_is_found_inside_a_nested_related_part
    m = parsed_fixture("nested-related.eml")

    assert m.html?
    assert_includes m.body, "The typeface that ate our budget"
    assert_includes m.body, 'src="cid:masthead@pixelwharf.example"'
    refute_includes m.body, "Studio notes at the bottom"
  end

  def test_the_inline_image_of_a_related_part_is_not_the_body
    m = parsed_fixture("nested-related.eml")

    refute_includes m.body, "iVBORw0KGgo"
  end

  # --- mixed-with-attachment.eml -------------------------------------------
  # multipart/mixed { multipart/alternative { plain, html }, text/plain
  # attachment, application/pdf }. The text/plain attachment is the trap: it is
  # a perfectly good text part, and it is not the newsletter. Attachments are
  # out of scope for the basic version, so they may only be ignored — never
  # picked up, never made into the body.

  def test_an_attachment_is_never_the_body
    m = parsed_fixture("mixed-with-attachment.eml")

    assert m.html?
    assert_includes m.body, "The tide table, with footnotes"
    refute_includes m.body, "COUPON TEXT THAT IS NOT THE NEWSLETTER BODY"
    refute_includes m.body, "JVBERi0xLjQ"
  end

  def test_the_alternative_inside_a_mixed_is_still_reached
    m = parsed_fixture("mixed-with-attachment.eml")

    assert_equal "Harbour Ledger", m.author
    assert_equal Time.utc(2026, 8, 7, 16, 2, 5), m.date
  end

  # --- plain-only.eml -------------------------------------------------------
  # One text/plain part, no MIME-Version, no alternative. F3's fallback: the
  # body is the plain text, and Phase 3 has to know it is not markup.

  def test_a_plain_only_message_falls_back_to_its_text
    m = parsed_fixture("plain-only.eml")

    refute m.html?
    assert_includes m.body, "There is no HTML version of this letter"
    assert_equal "Sluice Notes", m.author
  end

  # --- html-only.eml --------------------------------------------------------
  # One quoted-printable text/html part and nothing else. `mail` finds no
  # "parts" in a single-part message, so html_part is nil and the message has
  # to stand in for its own body part.

  def test_a_single_part_html_message_is_its_own_body
    m = parsed_fixture("html-only.eml")

    assert m.html?
    assert_includes m.body, "<h1 style=\"font-size:20px;\">BrightGrid Digest</h1>"
    # Decoded, not raw: quoted-printable soft breaks and =3D must be gone.
    refute_includes m.body, "=3D"
    refute_includes m.body, "=\n"
  end

  # --- encoded-word-subject.eml --------------------------------------------
  # RFC 2047 in both flavours in one Subject (=?UTF-8?B?= then =?UTF-8?Q?=),
  # an encoded display name in From, and base64 UTF-8 bodies with Polish
  # diacritics. A title rendered as "=?UTF-8?B?..." in the reader would be a
  # silent F4 failure — nothing raises, it just looks like garbage.

  def test_encoded_words_are_decoded_in_the_subject_and_the_author
    m = parsed_fixture("encoded-word-subject.eml")

    assert_equal "Żółta Latarnia #12: gęsi, świerszcze i łąka", m.title
    assert_equal "Żółta Latarnia", m.author
    assert_equal Encoding::UTF_8, m.title.encoding
  end

  def test_a_base64_body_comes_back_as_text
    m = parsed_fixture("encoded-word-subject.eml")

    assert m.html?
    assert_includes m.body, "Gęsi, świerszcze i łąka"
    refute_includes m.body, "PCFET0NUWVBF"
  end

  # --- iso8859-2-quoted-printable.eml --------------------------------------
  # A message that is honestly not UTF-8: ISO-8859-2 throughout, quoted-
  # printable body, encoded-word Subject in the same charset. Proves the
  # transcode is a real transcode and not a force_encoding — 0xB6 is "ś" here
  # and "¶" almost everywhere else.

  def test_a_non_utf8_charset_is_transcoded_not_reinterpreted
    m = parsed_fixture("iso8859-2-quoted-printable.eml")

    assert_equal "Biuletyn Zielarski nr 5: pokrzywa i świetlik", m.title
    assert_equal "Zespół Zielarski", m.author
    assert_includes m.body, "Pokrzywa i świetlik"
    assert_includes m.body, "nie sadził"
    refute_includes m.body, "¶"
  end

  # --- ugly-no-subject-no-date.eml -----------------------------------------
  # A bulk mailer with no Subject, no Date, no Message-ID, no Received and a
  # From with no address in it. TODO 4 of this phase, in one file: none of it
  # may raise, and all of it has to produce an entry.

  def test_a_message_with_no_subject_gets_a_placeholder_title
    assert_equal Mail2rss26::Message::NO_SUBJECT, parsed_fixture("ugly-no-subject-no-date.eml").title
  end

  def test_a_message_with_no_date_anywhere_falls_back_to_the_epoch
    m = parsed_fixture("ugly-no-subject-no-date.eml")

    assert_equal Mail2rss26::Message::EPOCH, m.date
    # N6: the fallback is a constant, not a clock. Two reads of the same bytes
    # are the same entry, today and in a year.
    assert_equal parsed_fixture("ugly-no-subject-no-date.eml").date, m.date
  end

  # --- fallback_date, which is Phase 4 improving on 1970 --------------------
  # The caller may know something the message does not. Phase 4 passes the
  # delivery timestamp out of the stored filename, so a newsletter that dated
  # itself nowhere is dated when it arrived instead of sorting to the bottom of
  # the reader forever. It is still not a clock: it is state on disk, read back
  # the same way on every render.

  def test_a_caller_supplied_date_beats_the_epoch
    delivered = Time.utc(2026, 8, 20, 11, 22, 33)
    assert_equal delivered, dated("ugly-no-subject-no-date.eml", delivered)
  end

  # It is a *fallback*, not an override: a message that dated itself keeps its
  # own date, or the delivery order of a mailbox would silently replace the
  # publication order a reader is sorting on.
  def test_a_caller_supplied_date_never_beats_the_message
    delivered = Time.utc(2026, 8, 20, 11, 22, 33)

    assert_equal Time.utc(2026, 8, 12, 6, 3, 16), dated("simple-multipart.eml", delivered)
    # Including when the date came from Received rather than from a Date header
    # this program could believe.
    assert_equal Time.utc(2026, 8, 17, 2, 31, 9), dated("ugly-lying-charset.eml", delivered)
  end

  def test_a_fallback_date_that_is_not_a_time_is_ignored_rather_than_raised
    assert_equal Mail2rss26::Message::EPOCH, dated("ugly-no-subject-no-date.eml", "yesterday")
  end

  # The same read the renderer does: bytes as they are on disk, plus whatever
  # the filename said.
  def dated(name, fallback)
    Mail2rss26::Message.parse(File.binread(fixture_path(name)), fallback_date: fallback).date
  end

  def test_an_unparseable_from_degrades_to_what_the_header_said
    m = parsed_fixture("ugly-no-subject-no-date.eml")

    assert_equal "Wielkie Okazje", m.author
    assert_nil m.author_email
  end

  def test_a_missing_message_id_is_derived_from_the_bytes
    m = parsed_fixture("ugly-no-subject-no-date.eml")

    assert_match(/\Asha256:[0-9a-f]{64}\z/, m.message_id)
    # F6 dedups on this, so the same delivery twice has to hash the same.
    assert_equal parsed_fixture("ugly-no-subject-no-date.eml").message_id, m.message_id
  end

  def test_the_ugly_message_still_has_a_body
    m = parsed_fixture("ugly-no-subject-no-date.eml")

    assert m.html?
    assert_includes m.body, "KUPUJĘ TERAZ"
  end

  # --- ugly-lying-charset.eml ----------------------------------------------
  # The other kind of ugly: a Date on the 32nd of August at 25:71, two Subject
  # headers, and a body declared us-ascii that is raw 8-bit UTF-8. `mail` alone
  # answers this one with a string full of U+FFFD.

  def test_an_unparseable_date_falls_back_to_the_received_header
    m = parsed_fixture("ugly-lying-charset.eml")

    # 04:31:09 +0200, the moment our own MTA stamped in — not the clock, and
    # not 1970 either, because the message did say when it arrived.
    assert_equal Time.utc(2026, 8, 17, 2, 31, 9), m.date
  end

  def test_a_duplicated_subject_header_resolves_to_one_title
    assert_equal "Ostatnia szansa: -40% tylko dzisiaj", parsed_fixture("ugly-lying-charset.eml").title
  end

  def test_a_lying_charset_does_not_cost_the_text
    m = parsed_fixture("ugly-lying-charset.eml")

    assert_includes m.body, "cały asortyment"
    assert_includes m.body, "Odbierz zniżkę"
    refute_includes m.body, "�"
  end

  def test_the_lying_charset_is_a_lie_that_mail_alone_falls_for
    # Guards the fixture, not the code: if some future `mail` starts doing this
    # for us, the transcoding in Message can go.
    naive = Mail.read(fixture_path("ugly-lying-charset.eml")).decoded

    assert_includes naive, "�"
  end

  # --- the whole fixture set ------------------------------------------------
  # The set is the specification. These two run over all of it, so a new
  # fixture is covered by them the moment it is added.

  def test_every_fixture_parses_into_the_complete_f4_field_set
    each_fixture do |name, m|
      refute_empty m.title, name
      refute_empty m.author, name
      refute_empty m.message_id, name
      assert_kind_of Time, m.date, name
      assert_equal "UTC", m.date.zone, name
    end
  end

  def test_every_fixture_yields_valid_utf8_and_never_raises_an_encoding_error
    each_fixture do |name, m|
      [m.title, m.author, m.body].each do |text|
        assert_equal Encoding::UTF_8, text.encoding, name
        assert text.valid_encoding?, "#{name}: #{text[0, 40].inspect} is not valid UTF-8"
      end
      refute_empty m.body, name
    end
  end

  private

  def each_fixture
    names = Dir.children(Mail2rss26::TestHelper::FIXTURES).grep(/\.eml\z/).sort
    assert_operator names.length, :>=, 5, "the fixture set is the specification; keep it fed"

    names.each { |name| yield name, parsed_fixture(name) }
  end
end
