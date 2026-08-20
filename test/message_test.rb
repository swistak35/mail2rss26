# frozen_string_literal: true

require_relative "test_helper"
require "mail"

# Phase 1 only proves the fixture is real and the one gem we allow ourselves can
# read it. The field-by-field parser is Phase 2.
class MessageTest < Minitest::Test
  def setup
    @mail = Mail.read(fixture_path("simple-multipart.eml"))
  end

  def test_parses_the_subject
    assert_equal "Issue 42: The quiet parts of a slow web", @mail.subject
  end

  def test_parses_the_envelope_fields_a_feed_entry_needs
    assert_equal "newsletter@lamplighter.example", @mail.from.first
    # `mail` hands back the id without its angle brackets; the Atom entry id is
    # built from this in Phase 3.
    assert_equal "20260812060316.4c1b9a7e@mail.lamplighter.example", @mail.message_id
    assert_equal 2026, @mail.date.year
  end

  def test_carries_both_alternatives
    assert @mail.multipart?
    assert_equal %w[text/plain text/html], @mail.parts.map { |p| p.mime_type }
    assert_includes @mail.html_part.decoded, "<h1"
    assert_includes @mail.text_part.decoded, "THE LAMPLIGHTER"
  end
end
