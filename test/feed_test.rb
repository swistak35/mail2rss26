# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# REXML, and only here. lib/mail2rss26/feed.rb explains at length why the
# generator does not use it — it is a bundled gem, so it is exactly the kind of
# require that works in the dev shell and raises LoadError on the server. In the
# test suite that risk is inverted into a feature: the assertions want a parser
# this project did *not* write, because "my serialiser round-trips through my
# serialiser" proves nothing about F2. The suite already depends on Minitest
# coming from the same directory, so this adds no new failure mode to the
# things that ship.
require "rexml/document"

# Phase 3: a directory of messages, out one Atom document (F2, F6, F7, N4, N6).
class FeedTest < Minitest::Test
  ATOM_NS = "http://www.w3.org/2005/Atom"

  # Feed identity as Phase 7 will supply it: a token that has nothing to do
  # with any incoming address (F8).
  FEED_ID = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21"
  FEED_TITLE = "Listy z odlewni & okolic"
  SELF_URL = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom"

  # --- the whole fixture set as one feed ------------------------------------
  # The fixture set is this program's specification, so the headline test is
  # "all of it, at once, through an independent parser".

  def test_the_whole_fixture_set_renders_to_a_parseable_atom_document
    doc = parse(feed(all_fixtures).to_atom)

    assert_equal "feed", doc.root.name
    assert_equal ATOM_NS, doc.root.namespace
    assert_equal FEED_ID, text_of(doc.root, "id")
    assert_equal FEED_TITLE, text_of(doc.root, "title")
    assert_equal all_fixtures.length, entries_of(doc).length
  end

  # RFC 4287 makes exactly these mandatory, and a reader that meets an entry
  # without one of them is entitled to drop the whole feed.
  def test_every_entry_carries_the_elements_atom_requires
    entries_of(parse(feed(all_fixtures).to_atom)).each do |entry|
      id = text_of(entry, "id")

      refute_nil id
      refute_empty text_of(entry, "title").to_s, id
      refute_nil text_of(entry, "updated"), id
      refute_empty text_of(entry.elements["author"], "name").to_s, id
      refute_nil entry.elements["content"], id
    end
  end

  def test_dates_are_rfc3339_utc_and_not_rfc2822
    doc = parse(feed(all_fixtures).to_atom)
    stamps = [text_of(doc.root, "updated")] +
             entries_of(doc).flat_map { |e| [text_of(e, "updated"), text_of(e, "published")] }

    stamps.each do |stamp|
      # "2026-08-18T07:13:55Z". The mail headers these came from say
      # "Tue, 18 Aug 2026 09:13:55 +0200"; putting that in an Atom date is the
      # classic way to produce a feed that validates nowhere.
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, stamp)
    end
  end

  def test_the_feed_names_itself_and_its_generator
    doc = parse(feed(all_fixtures).to_atom)
    link = doc.root.elements["link"]

    assert_equal "self", link.attributes["rel"]
    assert_equal SELF_URL, link.attributes["href"]
    assert_equal Mail2rss26::VERSION, doc.root.elements["generator"].attributes["version"]
  end

  # The self link is the unguessable URL (F8), so a caller may prefer not to
  # write it into the file at all. Without it the feed is still valid.
  def test_a_feed_without_a_self_url_omits_the_link
    xml = Mail2rss26::Feed.new(id: FEED_ID, title: FEED_TITLE, messages: all_fixtures).to_atom

    assert_nil parse(xml).root.elements["link"]
    refute_includes xml, "<link"
  end

  # --- F3 into Atom: which content type, and no sanitising ------------------

  def test_the_content_type_follows_the_part_that_won
    by_id = entries_by_id(feed(all_fixtures).to_atom)

    assert_equal "html", by_id.fetch(entry_id("simple-multipart.eml")).elements["content"].attributes["type"]
    assert_equal "text", by_id.fetch(entry_id("plain-only.eml")).elements["content"].attributes["type"]
  end

  # Settled [2026-08-20 czw]: we escape the markup for XML and we do not clean
  # it. Readers sanitise anyway; doing it here would be a dependency and a way
  # to mangle content. So the nastiest thing a newsletter can contain has to
  # come back out of the parser exactly as it went in.
  def test_html_is_escaped_for_xml_and_not_sanitised
    nasty = %(<p onclick="alert('x')">a &amp; b</p><script>var t = 1 < 2;</script>)
    m = synthetic(body: nasty, content_type: "text/html; charset=UTF-8")
    entry = entries_of(parse(feed([m]).to_atom)).first

    assert_equal "html", entry.elements["content"].attributes["type"]
    assert_equal nasty, content_of(entry)
  end

  def test_a_plain_text_body_is_marked_as_text
    m = synthetic(body: "Nie ma wersji HTML.\n", content_type: "text/plain; charset=UTF-8")
    entry = entries_of(parse(feed([m]).to_atom)).first

    assert_equal "text", entry.elements["content"].attributes["type"]
    assert_equal "Nie ma wersji HTML.\n", content_of(entry)
  end

  def test_a_subject_full_of_markup_survives_as_a_title
    m = synthetic(subject: %(A & B <b>"C"</b> > D), body: "x")
    xml = feed([m]).to_atom

    assert_equal %(A & B <b>"C"</b> > D), text_of(entries_of(parse(xml)).first, "title")
    refute_includes xml, "<b>"
  end

  # An attachment-only message parses to an empty body (Phase 2's line: that is
  # a valid empty entry, not a delivery failure). Atom lets an entry omit
  # <content> only if it has a rel="alternate" link, and there is nowhere for
  # one to point, so the element is written empty instead.
  def test_an_empty_body_still_gets_a_content_element
    m = synthetic(body: "", content_type: "application/pdf")
    entry = entries_of(parse(feed([m]).to_atom)).first

    refute_nil entry.elements["content"]
    assert_equal "", content_of(entry)
  end

  # control-characters.eml: a template engine leaving NUL, BEL, VT, FF and ESC
  # in the body. XML 1.0 has no way to represent any of them — not even as a
  # character reference — so one of them anywhere costs F2 for every entry in
  # the feed at once. This is the one thing we do remove from a body.
  def test_control_bytes_are_dropped_so_the_document_stays_parseable
    m = parsed_fixture("control-characters.eml")

    illegal = m.body.bytes.select { |b| b < 0x20 && ![0x09, 0x0A, 0x0D].include?(b) }

    refute_empty illegal, "the fixture is only worth keeping while it still carries control bytes"

    entry = entries_of(parse(feed([m]).to_atom)).first
    body = content_of(entry)

    assert_includes body, "<h1>Foundry Weekly #7</h1>"
    assert_empty body.bytes.select { |b| b < 0x20 && ![0x09, 0x0A].include?(b) }
  end

  # --- entry ids (F6's key, in IRI clothing) --------------------------------

  def test_a_real_message_id_becomes_a_mid_uri
    assert_equal "mid:20260812060316.4c1b9a7e@mail.lamplighter.example",
                 entry_id("simple-multipart.eml")
  end

  def test_a_synthetic_message_id_becomes_a_sha256_urn
    id = entry_id("ugly-no-subject-no-date.eml")

    # mid: would claim the message had a Message-ID, and the whole point of
    # this branch is that it did not.
    assert_match(%r{\Aurn:sha256:[0-9a-f]{64}\z}, id)
  end

  def test_a_message_id_full_of_illegal_characters_still_yields_an_iri
    m = synthetic(message_id: "<a b/c?d#e[f]ż@example.com>")

    assert_equal "mid:a%20b%2Fc%3Fd%23e%5Bf%5D%C5%BC@example.com", entry_id_of(m)
  end

  def test_every_entry_id_is_ascii_and_absolute
    entries_of(parse(feed(all_fixtures).to_atom)).each do |entry|
      id = text_of(entry, "id")

      assert id.ascii_only?, id
      assert_match(%r{\A(mid|urn):}, id)
      refute_match(/\s/, id)
    end
  end

  # F8, from the other side. The entry id is deliberately not derived from the
  # feed's id: that id is a secret token, and rotating a secret must not turn
  # every entry into a new one and re-notify the reader about a year of back
  # issues.
  def test_entry_ids_do_not_depend_on_the_feed_identity
    messages = all_fixtures
    other = Mail2rss26::Feed.new(id: "urn:uuid:00000000-0000-4000-8000-000000000000",
                                 title: "Something else", messages: messages)

    assert_equal entries_by_id(feed(messages).to_atom).keys,
                 entries_by_id(other.to_atom).keys
  end

  # F8 again: the address a newsletter was delivered to must not be derivable
  # from the feed, so it may not simply be *printed* in it either. Nothing here
  # reads To, Delivered-To or Received, and this is the test that keeps it that
  # way when someone later adds a field "because it is in the message anyway".
  def test_the_incoming_address_never_reaches_the_feed
    xml = feed(all_fixtures).to_atom

    assert_includes fixture("control-characters.eml"), "odlewnia.7c31e9@feeds.lasocha.net"
    refute_includes xml, "odlewnia.7c31e9"
    refute_includes xml, "Received:"
  end

  # --- F6: one message, delivered twice, is one entry -----------------------

  def test_the_same_message_twice_collapses_to_one_entry
    twice = [parsed_fixture("simple-multipart.eml"), parsed_fixture("simple-multipart.eml")]
    entries = entries_of(parse(feed(twice).to_atom))

    assert_equal 1, entries.length
    assert_equal "mid:20260812060316.4c1b9a7e@mail.lamplighter.example", text_of(entries.first, "id")
  end

  # The same, for the message that had no Message-ID of its own: Phase 2 hashes
  # its bytes precisely so that F6 keeps working here.
  def test_a_message_without_a_message_id_still_dedups
    twice = [parsed_fixture("ugly-no-subject-no-date.eml"), parsed_fixture("ugly-no-subject-no-date.eml")]

    assert_equal 1, entries_of(parse(feed(twice).to_atom)).length
  end

  def test_two_deliveries_of_the_same_message_on_disk_render_one_entry
    Dir.mktmpdir do |dir|
      body = fixture("simple-multipart.eml")
      File.write(File.join(dir, "20260812060316-a.eml"), body)
      File.write(File.join(dir, "20260814093000-b.eml"), body)

      feed = Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE)

      assert_equal 2, Dir.children(dir).length, "both deliveries stay on disk"
      assert_equal 1, entries_of(parse(feed.to_atom)).length
    end
  end

  # --- F7: N most recent, older ones drop at render time --------------------

  def test_the_feed_keeps_at_most_the_retention_limit
    messages = (1..(Mail2rss26::Feed::MAX_ENTRIES + 12)).map do |n|
      synthetic(message_id: "<#{format("%04d", n)}@example.com>",
                date: Time.utc(2026, 1, 1, 0, 0, 0) + (n * 3600))
    end

    entries = entries_of(parse(feed(messages.shuffle).to_atom))

    assert_equal Mail2rss26::Feed::MAX_ENTRIES, entries.length
  end

  def test_retention_drops_the_oldest_and_keeps_the_newest
    messages = (1..(Mail2rss26::Feed::MAX_ENTRIES + 2)).map do |n|
      synthetic(message_id: "<#{format("%04d", n)}@example.com>",
                date: Time.utc(2026, 1, 1, 0, 0, 0) + (n * 3600))
    end
    ids = entries_of(parse(feed(messages).to_atom)).map { |e| text_of(e, "id") }

    assert_equal "mid:#{format("%04d", Mail2rss26::Feed::MAX_ENTRIES + 2)}@example.com", ids.first
    refute_includes ids, "mid:0001@example.com"
    refute_includes ids, "mid:0002@example.com"
  end

  def test_entries_are_newest_first
    stamps = entries_of(parse(feed(all_fixtures).to_atom)).map { |e| text_of(e, "updated") }

    assert_equal stamps.sort.reverse, stamps
  end

  # --- N6: the same messages give the same bytes ----------------------------

  def test_rendering_twice_is_byte_identical
    assert_equal feed(all_fixtures).to_atom, feed(all_fixtures).to_atom
  end

  def test_writing_twice_is_byte_identical
    Dir.mktmpdir do |dir|
      copy_fixtures_into(dir)
      path = File.join(dir, "atom.xml")

      Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE, self_url: SELF_URL).write(path)
      first = File.binread(path)
      Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE, self_url: SELF_URL).write(path)

      assert_equal first, File.binread(path)
    end
  end

  # Dir.glob hands back readdir order, which is a hash order on ext4 and a
  # different hash order on a restored backup. Feed sorts the names for exactly
  # this reason; shuffling the messages proves the sort is not the only thing
  # holding the order up.
  def test_the_input_order_does_not_change_the_output
    messages = all_fixtures
    reference = feed(messages).to_atom

    5.times { assert_equal reference, feed(messages.shuffle).to_atom }
  end

  # The sharp edge in N6: sorting on the date alone is not a total order.
  # Ruby's sort is not stable and every message with neither a Date nor a
  # Received header lands on the same instant, so without the Message-ID
  # tie-break two runs over one directory can order the entries differently.
  def test_messages_sharing_a_timestamp_are_ordered_by_message_id
    tied = %w[ccc bbb aaa].map do |name|
      synthetic(message_id: "<#{name}@example.com>", date: Mail2rss26::Message::EPOCH)
    end
    ids = entries_of(parse(feed(tied).to_atom)).map { |e| text_of(e, "id") }

    assert_equal ["mid:aaa@example.com", "mid:bbb@example.com", "mid:ccc@example.com"], ids
    assert_equal ids, entries_of(parse(feed(tied.shuffle).to_atom)).map { |e| text_of(e, "id") }
  end

  # The feed's own <updated> comes from the newest entry. Time.now here would
  # make N6 false by construction, and would also teach every reader to treat a
  # re-render as news.
  def test_the_feed_timestamp_comes_from_the_entries_not_the_clock
    doc = parse(feed(all_fixtures).to_atom)
    newest = entries_of(doc).map { |e| text_of(e, "updated") }.max

    assert_equal newest, text_of(doc.root, "updated")
  end

  def test_an_empty_feed_is_still_valid_and_dated_from_the_epoch
    doc = parse(feed([]).to_atom)

    assert_empty entries_of(doc)
    assert_equal "1970-01-01T00:00:00Z", text_of(doc.root, "updated")
  end

  # --- N4: the reader never sees half a file --------------------------------

  def test_the_write_is_atomic_and_leaves_no_scratch_file_behind
    Dir.mktmpdir do |dir|
      copy_fixtures_into(dir)
      path = File.join(dir, "atom.xml")
      feed = Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE)

      assert_equal path, feed.write(path)
      assert_equal feed.to_atom.b, File.binread(path)
      assert_empty Dir.children(dir).grep(/\.tmp\z/)
    end
  end

  def test_a_rewrite_replaces_the_previous_feed_in_place
    Dir.mktmpdir do |dir|
      path = File.join(dir, "atom.xml")
      File.write(path, "<!-- a much longer document that used to be here -->\n" * 20)
      feed([parsed_fixture("plain-only.eml")]).write(path)

      assert_equal 1, entries_of(parse(File.binread(path))).length
    end
  end

  # N3: a feed we could not write is our side failing, not a newsletter being
  # ugly. It has to be loud, because the exit code is what keeps the message in
  # the OpenSMTPD queue.
  def test_an_unwritable_destination_raises_rather_than_reporting_success
    assert_raises(Errno::ENOENT) do
      feed(all_fixtures).write("/nonexistent-directory-for-mail2rss26/atom.xml")
    end
  end

  def test_a_missing_feed_directory_raises_rather_than_rendering_an_empty_feed
    assert_raises(Errno::ENOENT) do
      Mail2rss26::Feed.from_directory("/nonexistent-directory-for-mail2rss26",
                                      id: FEED_ID, title: FEED_TITLE)
    end
  end

  # --- reading a directory --------------------------------------------------

  # Phase 4's improvement on 1970, from the renderer's side: the timestamp
  # `ingest` wrote into the filename is handed to each message as its fallback
  # date. It is state on disk, so a render still asks the clock nothing (N6) —
  # this is the one place the two halves of that mechanism meet.
  def test_a_dateless_message_is_dated_from_its_filename
    Dir.mktmpdir do |dir|
      delivered = Time.utc(2026, 8, 20, 9, 15, 42)
      name = Mail2rss26::Store.filename(delivered, "sha256:#{"ab" * 32}")
      File.binwrite(File.join(dir, name), File.binread(fixture_path("ugly-no-subject-no-date.eml")))

      feed = Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE)

      assert_equal delivered, feed.entries.first.date
      assert_equal "2026-08-20T09:15:42Z", text_of(entries_of(parse(feed.to_atom)).first, "updated")
    end
  end

  # A file this program did not name — copied in by hand, or restored from an
  # archive that predates the convention — has no timestamp to read, and is
  # dated exactly as it was before Phase 4 rather than refused.
  def test_a_foreign_filename_falls_all_the_way_back_to_the_epoch
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "some-newsletter.eml"),
                    File.binread(fixture_path("ugly-no-subject-no-date.eml")))

      feed = Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE)

      assert_equal Mail2rss26::Message::EPOCH, feed.entries.first.date
    end
  end

  def test_from_directory_reads_every_eml_and_nothing_else
    Dir.mktmpdir do |dir|
      copy_fixtures_into(dir)
      # The rendered feed lives in the same directory as the messages, so the
      # glob has to be narrow enough not to try parsing it as a newsletter.
      File.write(File.join(dir, "atom.xml"), "<feed/>")
      File.write(File.join(dir, "notes.txt"), "not a message")

      feed = Mail2rss26::Feed.from_directory(dir, id: FEED_ID, title: FEED_TITLE)

      assert_equal fixture_names.length, feed.messages.length
    end
  end

  private

  def feed(messages)
    Mail2rss26::Feed.new(id: FEED_ID, title: FEED_TITLE, self_url: SELF_URL, messages: messages)
  end

  def fixture_names
    Dir.children(Mail2rss26::TestHelper::FIXTURES).grep(/\.eml\z/).sort
  end

  def all_fixtures
    fixture_names.map { |name| parsed_fixture(name) }
  end

  def copy_fixtures_into(dir)
    fixture_names.each { |name| File.binwrite(File.join(dir, name), File.binread(fixture_path(name))) }
  end

  # A message that exists to exercise one edge of the generator rather than one
  # edge of a real mailer — those belong in test/fixtures/, next to the fix.
  def synthetic(subject: "Synthetic", from: "Nadawca <listy@example.com>",
                date: Time.utc(2026, 6, 1, 12, 0, 0), message_id: "<synthetic@example.com>",
                content_type: "text/html; charset=UTF-8", body: "<p>hello</p>")
    headers = [
      "From: #{from}",
      "Subject: #{subject}",
      "Date: #{date.utc.strftime("%a, %-d %b %Y %H:%M:%S +0000")}",
      "Message-ID: #{message_id}",
      "MIME-Version: 1.0",
      "Content-Type: #{content_type}",
      "Content-Transfer-Encoding: 8bit"
    ]
    # Assembled rather than heredoc'd because several tests assert on the body
    # byte for byte, and a heredoc quietly appends a newline they did not ask
    # for.
    Mail2rss26::Message.parse("#{headers.join("\n")}\n\n#{body}".b)
  end

  def parse(xml)
    REXML::Document.new(xml)
  end

  def entries_of(doc)
    doc.get_elements("/feed/entry")
  end

  def entries_by_id(xml)
    entries_of(parse(xml)).to_h { |entry| [text_of(entry, "id"), entry] }
  end

  def text_of(element, name)
    child = element&.elements&.[](name)
    child && child.texts.map(&:value).join
  end

  # <content> arrives as one or more text nodes; joining them is what turns an
  # escaped body back into the bytes the message had.
  def content_of(entry)
    entry.elements["content"].texts.map(&:value).join
  end

  def entry_id(fixture_name)
    entry_id_of(parsed_fixture(fixture_name))
  end

  def entry_id_of(message)
    text_of(entries_of(parse(feed([message]).to_atom)).first, "id")
  end
end
