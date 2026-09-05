# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

# The operator's three commands, driven through CLI.run the way a person at a
# terminal drives them.
#
# The assertions are mostly about *what is in the output* rather than about the
# exact table, because a column that moves is not a regression and pinning one
# would only make this file expensive to keep. The two things pinned tightly
# are the exit codes — they are outside the delivery contract on purpose — and
# the facts the journal exists to expose.
class ViewerTest < Minitest::Test
  WEEKLY = "weekly.a41f9d@feeds.lasocha.net"
  OKAZJE = "okazje.3f1c@feeds.lasocha.net"

  def setup
    @tmp = Dir.mktmpdir("mail2rss26-viewer")
    @state = File.join(@tmp, "state")
    Dir.mkdir(@state)
    @config = File.join(@tmp, "feeds.json")
    File.write(@config, JSON.generate(document))
    # A width the tests control, so the same table comes out in a pipe, under
    # sudo and on a laptop. See Viewer::DEFAULT_WIDTH.
    @columns = ENV["COLUMNS"]
    ENV["COLUMNS"] = "200"
  end

  def teardown
    ENV["COLUMNS"] = @columns
    FileUtils.remove_entry(@tmp)
  end

  def document
    {
      "version" => 1,
      "stateDir" => @state,
      "feeds" => {
        "lamplighter" => {
          "title" => "The Lamplighter",
          "id" => "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21",
          "addresses" => [WEEKLY]
        },
        "okazje" => {
          "title" => "Wielkie Okazje",
          "id" => "urn:uuid:1f0f2f6c-3c6a-4a3f-9d0b-2a1b8f4c7e35",
          "addresses" => [OKAZJE]
        }
      }
    }
  end

  # --- log ------------------------------------------------------------------

  def test_log_shows_every_outcome_a_delivery_can_have
    ingest(WEEKLY, "simple-multipart.eml")
    ingest(WEEKLY, "simple-multipart.eml")
    ingest("nikt@feeds.lasocha.net", "plain-only.eml")
    run_cli("ingest", "--recipient", WEEKLY, "--config", "/nowhere.json", "--state-dir", @state)

    code, out, = run_cli("log", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_includes out, "stored"
    assert_includes out, "duplicate"
    assert_includes out, "no-feed"
    assert_includes out, "deferred"
    assert_includes out, "Issue 42: The quiet parts of a slow web"
  end

  def test_log_is_newest_first
    ingest(WEEKLY, "simple-multipart.eml")
    ingest(OKAZJE, "iso8859-2-quoted-printable.eml")

    code, out, err = run_cli("log", "--config", @config)
    assert_equal Mail2rss26::CLI::EX_OK, code, err
    rows = out.lines.drop(1)
    refute_empty rows, err

    assert_match(/\bokazje\b/, rows.first)
    assert_match(/\blamplighter\b/, rows.last)
  end

  def test_log_filters_by_feed_and_outcome
    ingest(WEEKLY, "simple-multipart.eml")
    ingest(OKAZJE, "iso8859-2-quoted-printable.eml")

    _, only_feed, = run_cli("log", "--config", @config, "--feed", "okazje")
    refute_includes only_feed, "lamplighter"

    code, only_stored, err = run_cli("log", "--config", @config, "--outcome", "stored")
    assert_equal Mail2rss26::CLI::EX_OK, code, err
    assert_equal 3, only_stored.lines.length, "a heading and the two deliveries; stderr: #{err}"
  end

  def test_an_outcome_that_is_not_in_the_vocabulary_is_refused
    code, _out, err = run_cli("log", "--config", @config, "--outcome", "bounced")

    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_includes err, "unknown outcome"
  end

  def test_since_takes_a_duration_or_a_date_and_nothing_else
    ingest(WEEKLY, "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_OK, run_cli("log", "--config", @config, "--since", "7d").first
    assert_equal Mail2rss26::CLI::EX_OK, run_cli("log", "--config", @config, "--since", "2020-01-01").first

    code, _out, err = run_cli("log", "--config", @config, "--since", "yesterday")
    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_includes err, "cannot read"
  end

  def test_json_answers_the_journal_lines_themselves
    ingest(WEEKLY, "simple-multipart.eml")

    _, out, = run_cli("log", "--config", @config, "--json")
    entry = JSON.parse(out.lines.first)

    assert_equal "stored", entry["outcome"]
    assert_equal "lamplighter", entry["feed"]
    assert_equal "exact", entry["match"]
    assert_equal "header", entry["date_source"]
  end

  # The command you reach for precisely when the feed list is what broke, so it
  # must not need the feed list to work.
  def test_log_works_without_a_readable_feed_list
    run_cli("ingest", "--recipient", WEEKLY, "--config", "/nowhere.json", "--state-dir", @state)

    code, out, = run_cli("log", "--config", "/nowhere.json", "--state-dir", @state)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_includes out, "deferred"
  end

  def test_an_empty_journal_says_so_rather_than_printing_a_bare_heading
    code, out, err = run_cli("log", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_empty out
    assert_includes err, "no deliveries recorded"
  end

  # The bug this exists to stop coming back, and it was found by the sandbox
  # rather than by the dev shell — which is the whole argument for `checks`
  # running with nothing in the environment.
  #
  # A delivery agent has no environment at all, so on the server
  # Encoding.default_external is US-ASCII. Anything read from disk without an
  # explicit encoding is then tagged US-ASCII, and the first Polish subject in
  # the journal makes String#strip raise Encoding::CompatibilityError. In the
  # dev shell, where LANG is set, none of it happens.
  def test_everything_read_from_disk_is_utf8_whatever_the_locale_says
    ingest(OKAZJE, "iso8859-2-quoted-printable.eml")

    with_default_external(Encoding::US_ASCII) do
      code, out, err = run_cli("log", "--config", @config)

      assert_equal Mail2rss26::CLI::EX_OK, code, err
      assert_includes out, "świetlik"

      code, out, err = run_cli("show", "5c0b771e", "--config", @config)
      assert_equal Mail2rss26::CLI::EX_OK, code, err
      assert_includes out, "świetlik"

      assert_equal Mail2rss26::CLI::EX_OK, run_cli("feeds", "--config", @config).first
    end
  end

  # --- show -----------------------------------------------------------------

  def test_show_joins_the_journals_account_to_the_message_on_disk
    ingest(WEEKLY, "simple-multipart.eml")

    code, out, = run_cli("show", "20260812060316.4c1b9a7e@mail.lamplighter.example", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_includes out, "stored (exit 0)"
    assert_includes out, "matched exactly"
    assert_includes out, "lamplighter"
    assert_includes out, "Issue 42: The quiet parts of a slow web"
    assert_includes out, "from the message's own Date header"
    assert_includes out, "text/html"
  end

  def test_show_finds_a_message_by_part_of_its_file_name
    ingest(WEEKLY, "simple-multipart.eml")

    _, out, = run_cli("show", "20260812T060316Z", "--config", @config)
    assert_includes out, "Issue 42"
  end

  def test_show_says_how_a_tagged_address_resolved
    ingest("weekly.a41f9d+list@feeds.lasocha.net", "simple-multipart.eml")

    _, out, = run_cli("show", "20260812060316", "--config", @config)
    assert_includes out, "stripping its +tag"
  end

  # The reason date_source exists: "no Date header, so we used the Received our
  # own smtpd stamped" is a fact about our parser that the .eml cannot tell you.
  def test_show_says_where_a_missing_date_came_from
    ingest(WEEKLY, "ugly-no-subject-no-date.eml")

    _, out, = run_cli("show", "sha256", "--config", @config)
    assert_includes out, "no date in the message at all"
  end

  # A refused delivery stores nothing, so its only handle is the Message-ID the
  # journal kept. Without that, the outcome you most want to look up is the one
  # that cannot be looked up.
  def test_show_finds_a_refused_delivery_even_though_nothing_was_stored
    ingest("nikt@feeds.lasocha.net", "simple-multipart.eml")

    code, out, = run_cli("show", "20260812060316", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_includes out, "no-feed (exit 67)"
    assert_includes out, "Issue 42"
    refute_includes out, "  file "
  end

  def test_asking_for_the_bytes_of_a_delivery_that_stored_none_fails_rather_than_writing_nothing
    ingest("nikt@feeds.lasocha.net", "simple-multipart.eml")

    code, out, err = run_cli("show", "20260812060316", "--raw", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_empty out
    assert_includes err, "not on disk"
  end

  def test_raw_is_the_bytes_that_arrived_byte_for_byte
    ingest(WEEKLY, "simple-multipart.eml")

    _, out, = run_cli("show", "20260812060316", "--raw", "--config", @config)
    assert_equal File.binread(fixture_path("simple-multipart.eml")), out
  end

  def test_headers_stop_at_the_blank_line
    ingest(WEEKLY, "plain-only.eml")

    _, out, = run_cli("show", "sluice.019", "--headers", "--config", @config)

    assert_includes out, "From: "
    refute_includes out, "three-strand hemp"
  end

  def test_body_is_the_part_that_became_the_entry
    ingest(WEEKLY, "plain-only.eml")

    _, out, = run_cli("show", "sluice.019", "--body", "--config", @config)
    assert_includes out, "three-strand hemp"
  end

  # On the day this ships, every message on the machine predates the journal.
  def test_show_finds_a_message_that_has_no_journal_entry_at_all
    ingest(WEEKLY, "simple-multipart.eml")
    FileUtils.rm_rf(File.join(@state, Mail2rss26::Journal::DIR))

    code, out, = run_cli("show", "20260812T060316Z", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_includes out, "no journal entry"
    assert_includes out, "Issue 42"
  end

  def test_show_needs_something_to_look_for
    code, _out, err = run_cli("show", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_includes err, "name a message"
  end

  def test_a_delivery_that_does_not_exist_is_a_failure_not_an_empty_answer
    code, _out, err = run_cli("show", "nothing-like-this", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_includes err, "no delivery matching"
  end

  # --- feeds ----------------------------------------------------------------

  def test_feeds_counts_what_is_on_disk_and_what_a_reader_sees
    2.times { ingest(WEEKLY, "simple-multipart.eml") }
    ingest(WEEKLY, "plain-only.eml")

    code, out, = run_cli("feeds", "--config", @config)
    row = out.lines.find { |line| line.start_with?("lamplighter") }

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_match(/lamplighter\s+2\s+2\s/, row)
    assert_includes row, WEEKLY
    assert_includes out, "okazje"
  end

  # A feed that is configured but has never received anything still has to
  # appear — an empty row is the answer to "is this deployed?".
  def test_a_feed_with_nothing_in_it_is_still_listed
    _, out, = run_cli("feeds", "--config", @config)
    assert_match(/okazje\s+0\s+0\s+-/, out)
  end

  def test_feeds_cannot_work_without_the_feed_list_and_says_which_file
    code, _out, err = run_cli("feeds", "--config", "/nowhere.json")

    assert_equal Mail2rss26::CLI::EX_FAILURE, code
    assert_includes err, "/nowhere.json"
  end

  private

  def ingest(recipient, fixture_name)
    code, _out, err = run_cli("ingest", "--recipient", recipient, "--config", @config,
                              stdin: StringIO.new(File.binread(fixture_path(fixture_name))))
    [code, err]
  end

  # Encoding.default_external is global and warns when it is assigned, which is
  # exactly why a test has to be the thing that sets it: no production code may
  # ever depend on its value.
  def with_default_external(encoding)
    previous = Encoding.default_external
    verbose = $VERBOSE
    $VERBOSE = nil
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = previous
    $VERBOSE = verbose
  end

  def run_cli(*argv, stdin: StringIO.new(""))
    out = StringIO.new
    err = StringIO.new
    code = Mail2rss26::CLI.run(argv, stdout: out, stderr: err, stdin: stdin)
    [code, out.string, err.string]
  end
end
