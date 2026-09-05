# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "stringio"
require "tmpdir"

# The delivery journal on its own: appending, reading back, and the two
# properties that matter more than either — that a failure to write one never
# becomes a failure to deliver, and that a file with a damaged line in it is
# still readable.
class JournalTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir("mail2rss26-journal")
    @stderr = StringIO.new
    @journal = Mail2rss26::Journal.new(@tmp, stderr: @stderr)
  end

  def teardown
    FileUtils.chmod_R("u+rwx", @tmp, force: true)
    FileUtils.remove_entry(@tmp)
  end

  # --- writing --------------------------------------------------------------

  def test_a_record_is_one_json_line_in_a_file_named_for_its_month
    @journal.record(at: Time.utc(2026, 9, 5, 11, 22, 33), outcome: "stored", feed: "lamplighter")

    path = File.join(@tmp, "journal", "2026-09.jsonl")
    assert_path_exists path

    lines = File.readlines(path, chomp: true)
    assert_equal 1, lines.length

    entry = JSON.parse(lines.first)
    assert_equal Mail2rss26::Journal::SCHEMA_VERSION, entry["v"]
    assert_equal "2026-09-05T11:22:33Z", entry["at"]
    assert_equal "stored", entry["outcome"]
    assert_equal "lamplighter", entry["feed"]
  end

  # The month comes from the instant written into the line, not from a second
  # look at the clock, so a delivery in the last second of a month cannot be
  # filed under the next one.
  def test_the_month_file_is_chosen_by_the_entrys_own_timestamp
    @journal.record(at: Time.utc(2026, 1, 31, 23, 59, 59), outcome: "stored")
    @journal.record(at: Time.utc(2026, 2, 1, 0, 0, 0), outcome: "stored")

    assert_equal ["2026-01.jsonl", "2026-02.jsonl"],
                 Dir.children(File.join(@tmp, "journal")).grep(/jsonl/).sort
  end

  def test_a_nil_field_is_left_out_rather_than_written_as_null
    @journal.record(outcome: "deferred", feed: nil, reason: "config")

    entry = JSON.parse(File.readlines(files.first, chomp: true).first)
    refute_includes entry.keys, "feed"
    assert_equal "config", entry["reason"]
  end

  def test_records_accumulate_in_the_order_they_were_written
    3.times { |i| @journal.record(outcome: "stored", feed: "f#{i}") }

    assert_equal %w[f0 f1 f2],
                 File.readlines(files.first, chomp: true).map { |line| JSON.parse(line)["feed"] }
  end

  # The rule the class exists to keep. A delivery whose .eml is safely on disk
  # must not be turned into a deferral because the note about it could not be
  # written — the convention is about the newsletter, not about the note.
  def test_a_journal_that_cannot_be_written_reports_and_returns_nil_instead_of_raising
    FileUtils.chmod(0o500, @tmp)

    assert_nil @journal.record(outcome: "stored", feed: "lamplighter")
    assert_includes @stderr.string, "could not write the delivery journal"
  end

  # --- reading --------------------------------------------------------------

  def test_entries_come_back_newest_first_across_months
    @journal.record(at: Time.utc(2026, 8, 1), outcome: "stored", feed: "old")
    @journal.record(at: Time.utc(2026, 9, 1), outcome: "stored", feed: "new")

    assert_equal %w[new old], @journal.entries.map { |entry| entry["feed"] }
  end

  def test_entries_filter_by_feed_and_by_outcome
    @journal.record(outcome: "stored", feed: "lamplighter")
    @journal.record(outcome: "duplicate", feed: "lamplighter")
    @journal.record(outcome: "stored", feed: "okazje")

    assert_equal 2, @journal.entries(feed: "lamplighter").length
    assert_equal 1, @journal.entries(outcome: "duplicate").length
    assert_equal 1, @journal.entries(feed: "lamplighter", outcome: "stored").length
  end

  def test_entries_filter_by_time
    @journal.record(at: Time.utc(2026, 9, 1), outcome: "stored", feed: "old")
    @journal.record(at: Time.utc(2026, 9, 30), outcome: "stored", feed: "new")

    assert_equal ["new"], @journal.entries(since: Time.utc(2026, 9, 15)).map { |entry| entry["feed"] }
  end

  def test_the_limit_stops_the_read_rather_than_trimming_the_result
    5.times { |i| @journal.record(outcome: "stored", feed: "f#{i}") }

    assert_equal %w[f4 f3], @journal.entries(limit: 2).map { |entry| entry["feed"] }
  end

  # A machine that lost power mid-append leaves half a line. Refusing to show
  # the other thousand deliveries because of it would be the wrong trade by a
  # wide margin.
  def test_a_half_written_line_is_skipped_and_the_rest_still_reads
    @journal.record(outcome: "stored", feed: "before")
    File.open(files.first, "a") { |file| file.write(%({"v":1,"at":"2026-09-05T11:2)) }
    @journal.record(outcome: "stored", feed: "after")

    assert_equal %w[after before], @journal.entries.map { |entry| entry["feed"] }
  end

  # Same reasoning one step forward in time: a newer binary writing v2 must not
  # make an older viewer useless.
  def test_a_line_from_a_future_schema_version_is_skipped
    @journal.record(outcome: "stored", feed: "known")
    File.open(files.first, "a") do |file|
      file.puts JSON.generate({ "v" => 99, "outcome" => "stored", "feed" => "future" })
    end

    assert_equal ["known"], @journal.entries.map { |entry| entry["feed"] }
  end

  # A machine deployed this morning has no journal directory at all, and the
  # viewer has to render that rather than blow up on it.
  def test_a_journal_that_does_not_exist_yet_is_empty_rather_than_an_error
    assert_empty Mail2rss26::Journal.new(File.join(@tmp, "nowhere")).entries
    assert_empty @stderr.string
  end

  # Not a nicety: OpenSMTPD runs deliveries concurrently, and two of them
  # appending at the same moment must not interleave inside a line.
  def test_concurrent_writers_produce_whole_lines
    pids = Array.new(4) do |writer|
      fork do
        journal = Mail2rss26::Journal.new(@tmp)
        10.times do |n|
          journal.record(outcome: "stored", feed: "f#{writer}",
                         subject: "x" * 500, message_id: "#{writer}-#{n}")
        end
        exit!(0)
      end
    end
    pids.each { |pid| Process.waitpid(pid) }

    lines = files.flat_map { |path| File.readlines(path, chomp: true) }
    assert_equal 40, lines.length
    lines.each { |line| assert_kind_of Hash, JSON.parse(line) }
    assert_equal 40, @journal.entries.length
  end

  # --- the pieces the viewer leans on ---------------------------------------

  # Deliberately not Time.iso8601: `time` is not one of the default gems the
  # require-audit cleared, so the journal parses its own format by hand and
  # this is what pins that it round-trips.
  def test_a_timestamp_survives_a_round_trip_and_a_bad_one_is_nil
    time = Time.utc(2026, 9, 5, 11, 22, 33)

    assert_equal time, Mail2rss26::Journal.parse_timestamp(Mail2rss26::Journal.timestamp(time))
    assert_nil Mail2rss26::Journal.parse_timestamp("yesterday")
    assert_nil Mail2rss26::Journal.parse_timestamp("2026-13-05T11:22:33Z")
    assert_nil Mail2rss26::Journal.parse_timestamp(nil)
  end

  def test_long_text_is_truncated_and_folded_onto_one_line
    assert_equal "a b c", Mail2rss26::Journal.truncate("  a\n b\tc ")

    long = Mail2rss26::Journal.truncate("x" * 500)
    assert_equal Mail2rss26::Journal::TEXT_LIMIT, long.length
    assert long.end_with?("…")
  end

  private

  def files
    Dir[File.join(@tmp, "journal", "*.jsonl")].sort
  end
end
