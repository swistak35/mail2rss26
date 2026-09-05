# frozen_string_literal: true

require_relative "test_helper"
require "fileutils"
require "json"
require "rbconfig"
require "rexml/document"
require "stringio"
require "tmpdir"

# Phase 4, the whole point of it: `cat fixture.eml | mail2rss26 ingest
# --recipient X` against a real directory, with a real config file, and an exit
# code at the end of it.
#
# Everything here runs against Dir.mktmpdir. Two of the tests go further and
# spawn bin/mail2rss26 as a process, because an exit code that only exists as a
# return value inside Minitest is not the thing OpenSMTPD reads.
class IngestTest < Minitest::Test
  FEED_ID = "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21"
  FEED_URL = "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom"

  # The addresses are the ones in the fixtures' To: headers — not because
  # anything reads To (F8 says nothing may), but because a fixture that claims
  # one address and is delivered to another is a confusing thing to debug.
  WEEKLY = "weekly.a41f9d@feeds.lasocha.net"
  OKAZJE = "okazje.3f1c@feeds.lasocha.net"

  # The two numbers OpenSMTPD reads as "keep this envelope and try again",
  # straight out of smtpd.c: EX_OSERR and EX_TEMPFAIL. Every other non-zero
  # status is MDA_PERMFAIL — a bounce, and a newsletter that is gone. N3 is a
  # statement about *this set*, not about non-zero-ness, so the tests below
  # assert membership of it rather than a particular number.
  DEFERRING = [71, 75].freeze

  def setup
    @tmp = Dir.mktmpdir("mail2rss26-ingest")
    @state = File.join(@tmp, "state")
    Dir.mkdir(@state)
    @config = File.join(@tmp, "feeds.json")
    File.write(@config, JSON.pretty_generate(document))
  end

  def teardown
    # The unwritable-directory test leaves a directory it cannot delete.
    FileUtils.chmod_R("u+rwx", @tmp, force: true)
    FileUtils.remove_entry(@tmp)
  end

  def document(state_dir: @state)
    {
      "version" => 1,
      "stateDir" => state_dir,
      "feeds" => {
        "lamplighter" => {
          "title" => "The Lamplighter",
          "id" => FEED_ID,
          "url" => FEED_URL,
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

  # --- the happy path -------------------------------------------------------

  def test_a_delivered_message_is_stored_and_the_feed_rendered
    code, _out, err = ingest(WEEKLY, "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_OK, code, err
    assert_empty err

    stored = messages_in("lamplighter")
    assert_equal 1, stored.length
    assert_equal File.binread(fixture_path("simple-multipart.eml")),
                 File.binread(File.join(feed_dir("lamplighter"), stored.first)),
                 "the .eml on disk is the bytes that arrived, byte for byte"

    doc = atom("lamplighter")
    assert_equal FEED_ID, text_of(doc.root, "id")
    assert_equal "The Lamplighter", text_of(doc.root, "title")
    assert_equal FEED_URL, doc.root.elements["link"].attributes["href"]
    assert_equal 1, entries_of(doc).length
    assert_equal "Issue 42: The quiet parts of a slow web", text_of(entries_of(doc).first, "title")
  end

  # The filename is dated from the *message*, not from the delivery, whenever
  # the message dated itself. That is what makes `ls` chronological and what
  # makes a redelivery land on the same name.
  def test_the_stored_name_carries_the_messages_own_date_and_its_id
    ingest(WEEKLY, "simple-multipart.eml")
    name = messages_in("lamplighter").first

    assert_equal Time.utc(2026, 8, 12, 6, 3, 16), Mail2rss26::Store.timestamp_of(name)
    assert_includes name, "20260812060316.4c1b9a7e@mail.lamplighter"
    assert_match(/-[0-9a-f]{16}\.eml\z/, name)
  end

  def test_a_second_feed_is_untouched_by_a_delivery_to_the_first
    ingest(WEEKLY, "simple-multipart.eml")

    refute File.exist?(feed_dir("okazje"))
  end

  def test_several_messages_accumulate_into_one_feed
    ingest(WEEKLY, "simple-multipart.eml")
    ingest(WEEKLY, "plain-only.eml")

    assert_equal 2, messages_in("lamplighter").length
    assert_equal 2, entries_of(atom("lamplighter")).length
  end

  # --- F5: an unknown recipient --------------------------------------------

  def test_an_unknown_recipient_is_refused_and_writes_nothing
    code, _out, err = ingest("nobody.deadbeef@feeds.lasocha.net", "simple-multipart.eml")

    assert_equal 67, code
    assert_equal Mail2rss26::CLI::EX_NOUSER, code
    # And it is the one failure this program deliberately keeps on the bounce
    # side of the line: there is no feed, there is not going to be one, and
    # deferring would only retry until the queue expired the envelope.
    refute_includes DEFERRING, code, "an unknown recipient must not defer"
    assert_includes err, "no feed is configured"
    assert_includes err, "nothing was written"
    # No feed directory and no .eml. F5 wanted this refused at SMTP time
    # anyway; reaching ingest at all means the two configurations disagree.
    #
    # The journal directory is the one thing that does appear, and it is the
    # exception the promise was always about the message: "nothing was written"
    # means none of the newsletter is kept, not that the refusal goes
    # unrecorded. A refusal that leaves no trace anywhere is precisely the
    # drift F5 cannot see.
    assert_empty stored_state
  end

  # OpenSMTPD replaces characters it considers suspicious with ":" when it
  # expands %{rcpt}, so a colon in a recipient is a strong hint about *why*
  # nothing matched — and the operator reading the mail log is the only person
  # who will ever see this line.
  def test_a_mangled_recipient_says_what_probably_happened
    _code, _out, err = ingest("weekly:a41f9d@feeds.lasocha.net", "simple-multipart.eml")

    assert_includes err, "OpenSMTPD substitutes"
  end

  def test_the_recipient_may_arrive_uppercased_bracketed_or_tagged
    ["<#{WEEKLY}>", WEEKLY.upcase, "weekly.a41f9d+list@feeds.lasocha.net"].each do |recipient|
      FileUtils.rm_rf(feed_dir("lamplighter"))
      code, _out, err = ingest(recipient, "simple-multipart.eml")

      assert_equal Mail2rss26::CLI::EX_OK, code, "#{recipient}: #{err}"
      assert_equal 1, messages_in("lamplighter").length
    end
  end

  # --- F6: the same message twice ------------------------------------------

  def test_a_redelivery_stores_nothing_new_and_leaves_the_feed_byte_identical
    ingest(WEEKLY, "simple-multipart.eml")
    first = File.binread(atom_path("lamplighter"))
    stored = messages_in("lamplighter")

    code, _out, _err = ingest(WEEKLY, "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_equal stored, messages_in("lamplighter"), "the second delivery is a no-op on disk"
    assert_equal first, File.binread(atom_path("lamplighter")), "and on the rendered feed (N6)"
    assert_equal 1, entries_of(atom("lamplighter")).length
  end

  # The redelivery of a message with no date of its own: the second delivery's
  # clock reads later, so the name it *would* get differs from the name on
  # disk. Matching on the id half of the name is what keeps it one entry.
  # Simulated by renaming, because the test cannot wait a second for the clock.
  def test_a_redelivery_under_a_later_clock_is_still_one_entry
    ingest(OKAZJE, "ugly-no-subject-no-date.eml")
    stored = messages_in("okazje").first
    id_half = stored.sub(/\A\d{8}T\d{6}Z/, "")
    File.rename(File.join(feed_dir("okazje"), stored),
                File.join(feed_dir("okazje"), "19991231T235959Z#{id_half}"))

    ingest(OKAZJE, "ugly-no-subject-no-date.eml")

    assert_equal 1, messages_in("okazje").length
    assert_equal 1, entries_of(atom("okazje")).length
  end

  # --- the 1970 fallback, which is why the filename has a timestamp ---------

  def test_a_message_with_no_date_is_dated_from_its_filename_not_from_1970
    before = Time.now.utc - 1
    ingest(OKAZJE, "ugly-no-subject-no-date.eml")

    stamp = Mail2rss26::Store.timestamp_of(messages_in("okazje").first)
    entry = entries_of(atom("okazje")).first

    refute_nil stamp
    assert_operator stamp, :>=, before
    assert_equal stamp.strftime("%Y-%m-%dT%H:%M:%SZ"), text_of(entry, "updated")
    refute_equal "1970-01-01T00:00:00Z", text_of(entry, "updated")
  end

  # N6 with the fallback in play: the delivery took the clock once, and every
  # render since reads that same instant back out of the filename. Rendering
  # again — a year later, on another machine, from a restored backup — has to
  # produce the same bytes.
  def test_re_rendering_a_dateless_message_is_byte_identical
    ingest(OKAZJE, "ugly-no-subject-no-date.eml")
    first = File.binread(atom_path("okazje"))

    assert_equal Mail2rss26::CLI::EX_OK, run_cli("render", "--feed", "okazje", "--config", @config).first
    assert_equal first, File.binread(atom_path("okazje"))
  end

  # --- our own side failing (N3) -------------------------------------------

  # A message delivered over SMTP cannot be zero bytes — DATA carries headers
  # and smtpd stamps a Received: on top of them — so zero bytes here never mean
  # "the envelope is empty", they mean the pipe between the queue and this
  # process is broken while the queue file still holds a whole newsletter.
  def test_nothing_on_stdin_defers_because_the_queue_still_has_the_message
    code, _out, err = run_cli("ingest", "--recipient", WEEKLY, "--config", @config,
                              stdin: StringIO.new(""))

    assert_includes DEFERRING, code
    assert_includes err, "nothing on stdin"
    assert_empty stored_state
  end

  # N3, stated as the property rather than as a number, and the reason this
  # file exists in the shape it does.
  #
  # The classic operational failure: the state directory is not writable by the
  # user OpenSMTPD runs the delivery as, or the disk is full, or the filesystem
  # went read-only. The newsletter must survive it — which means the exit code
  # has to be one OpenSMTPD *defers* on, and only 71 and 75 are. This program
  # used to answer 74 (EX_IOERR) here, the most descriptive number available
  # and a MDA_PERMFAIL: the one failure documented as "a retry helps" was the
  # one that bounced the mail. If a later edit swaps 75 back for something
  # informative, this test fails instead of the mail quietly disappearing.
  def test_a_transient_io_failure_exits_with_a_code_opensmtpd_will_defer
    skip "root ignores the mode bits" if Process.uid.zero?

    File.chmod(0o500, @state)
    code, _out, err = ingest(WEEKLY, "simple-multipart.eml")

    assert_includes DEFERRING, code,
                    "exit #{code} is MDA_PERMFAIL to smtpd — the newsletter would bounce, not queue"
    assert_includes err, "Permission denied"
    # And nothing half-written for the retry to trip over.
    assert_empty Dir.children(@state)
  end

  # The same failure in a form even root cannot ignore, so it is checked
  # wherever the suite runs: a state directory that is a regular file.
  def test_a_state_directory_that_is_not_a_directory_defers_the_message
    path = File.join(@tmp, "not-a-directory")
    File.write(path, "")
    File.write(@config, JSON.generate(document(state_dir: path)))

    code, _out, err = ingest(WEEKLY, "simple-multipart.eml")

    assert_includes DEFERRING, code
    refute_empty err
  end

  # An operator problem, not an I/O hiccup — and it defers for exactly that
  # reason. The envelope got this far because smtpd.conf accepted the address,
  # and smtpd.conf and feeds.json are generated from the same option, so a
  # corrected file delivers it. Under the old contract this answered 78 and
  # bounced every newsletter that arrived during a bad deploy.
  def test_a_malformed_config_defers_the_delivery_instead_of_bouncing_it
    File.write(@config, "{ not json")
    code, _out, err = ingest(WEEKLY, "simple-multipart.eml")

    assert_includes DEFERRING, code
    assert_includes err, "not valid JSON"
    assert_empty Dir.children(@state)
  end

  # The undecidable row, pinned so the judgement has to be made again rather
  # than drifted past: a crash we did not classify might be deterministic in
  # this newsletter's bytes, but we cannot know that from inside it, and
  # bouncing throws the message away while a fix released this afternoon could
  # still have delivered it.
  def test_an_unclassified_exception_defers_and_puts_the_backtrace_on_stderr
    code, _out, err = run_cli("ingest", "--recipient", WEEKLY, "--config", @config,
                              stdin: Kaboom.new)

    assert_includes DEFERRING, code
    assert_includes err, "RuntimeError: kaboom"
    # The backtrace is the only bug report a delivery ever files, and it is now
    # carrying the whole diagnostic load that a distinct exit code used to
    # pretend to carry.
    assert_match(/^ {2}\S+cli\.rb:\d+/, err)
  end

  # Not a SystemCallError and not an IOError, so it falls through to the
  # catch-all: exactly the shape of a bug in a parser that some future
  # newsletter trips over.
  class Kaboom < StringIO
    def read(*)
      raise "kaboom"
    end
  end

  # --- render, the other half of the command line --------------------------

  def test_render_rebuilds_every_configured_feed
    ingest(WEEKLY, "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_OK, run_cli("render", "--config", @config).first
    # Including the one that has never had a delivery: a valid empty document
    # beats a 404 for a feed somebody has already subscribed to.
    assert_equal 1, entries_of(atom("lamplighter")).length
    assert_empty entries_of(atom("okazje"))
  end

  # A configuration change with no delivery: the title and the rotated URL have
  # to reach the file nginx serves, and the Atom <id> must not move with them.
  def test_render_picks_up_a_retitled_feed_and_a_rotated_url
    ingest(WEEKLY, "simple-multipart.eml")
    changed = document
    changed["feeds"]["lamplighter"]["title"] = "The Lamplighter (weekly)"
    changed["feeds"]["lamplighter"]["url"] = "https://feeds.lasocha.net/0000000000000000.atom"
    File.write(@config, JSON.generate(changed))

    run_cli("render", "--feed", "lamplighter", "--config", @config)
    doc = atom("lamplighter")

    assert_equal "The Lamplighter (weekly)", text_of(doc.root, "title")
    assert_equal "https://feeds.lasocha.net/0000000000000000.atom",
                 doc.root.elements["link"].attributes["href"]
    assert_equal FEED_ID, text_of(doc.root, "id")
  end

  def test_render_of_a_feed_that_is_not_configured_is_refused
    code, _out, err = run_cli("render", "--feed", "nosuchfeed", "--config", @config)

    assert_equal Mail2rss26::CLI::EX_NOUSER, code
    assert_includes err, "no feed named"
  end

  def test_the_state_dir_flag_beats_the_config
    other = File.join(@tmp, "elsewhere")
    Dir.mkdir(other)
    code, _out, _err = ingest(WEEKLY, "simple-multipart.eml", "--state-dir", other)

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_empty Dir.children(@state)
    assert_equal 1, Dir.children(File.join(other, "lamplighter")).grep(/\.eml\z/).length
  end

  # --- the real binary, because the exit code is the interface -------------

  def test_the_binary_exits_zero_after_a_delivery
    code, output = run_binary("ingest", "--recipient", WEEKLY, "--config", @config,
                              input: File.binread(fixture_path("simple-multipart.eml")))

    assert_equal 0, code, output
    assert_empty output
    assert_equal 1, entries_of(atom("lamplighter")).length
  end

  def test_the_binary_exits_with_the_documented_code_for_an_unknown_recipient
    code, output = run_binary("ingest", "--recipient", "nobody@feeds.lasocha.net", "--config", @config,
                              input: File.binread(fixture_path("simple-multipart.eml")))

    assert_equal 67, code
    assert_includes output, "no feed is configured"
    assert_empty stored_state
  end

  # The same N3 property as above, but read off a real process the way smtpd
  # reads it — a wait status, not a return value inside Minitest.
  def test_the_binary_exits_with_a_deferring_code_when_the_state_dir_is_unwritable
    skip "root ignores the mode bits" if Process.uid.zero?

    File.chmod(0o500, @state)
    code, output = run_binary("ingest", "--recipient", WEEKLY, "--config", @config,
                              input: File.binread(fixture_path("simple-multipart.eml")))

    assert_includes DEFERRING, code, output
    assert_includes output, "Permission denied"
  end

  # --- the delivery journal -------------------------------------------------
  #
  # The journal is a record *of* deliveries, so these live here rather than in
  # journal_test.rb: what is pinned is that every exit code the contract can
  # produce leaves a line behind, and — the important one — that the journal
  # can never change what that exit code is.

  def test_a_delivery_leaves_a_journal_line_naming_the_feed_the_file_and_the_match
    ingest(WEEKLY, "simple-multipart.eml")

    entry = journal.first
    assert_equal "stored", entry["outcome"]
    assert_equal Mail2rss26::CLI::EX_OK, entry["exit"]
    assert_equal "lamplighter", entry["feed"]
    assert_equal WEEKLY, entry["recipient"]
    assert_equal "exact", entry["match"]
    assert_equal messages_in("lamplighter").first, entry["file"]
    assert_equal "Issue 42: The quiet parts of a slow web", entry["subject"]
    assert_equal "header", entry["date_source"]
    assert_equal File.size(fixture_path("simple-multipart.eml")), entry["bytes"]
  end

  # A redelivery is a no-op against the disk by design, which used to mean it
  # was invisible. It is the one outcome you cannot deduce from the state
  # directory, because nothing about the state directory changed.
  def test_a_redelivery_is_recorded_as_a_duplicate_and_names_the_file_we_already_had
    ingest(WEEKLY, "simple-multipart.eml")
    ingest(WEEKLY, "simple-multipart.eml")

    assert_equal %w[duplicate stored], journal.map { |entry| entry["outcome"] }
    assert_equal 1, messages_in("lamplighter").length
    assert_equal journal.last["file"], journal.first["file"]
  end

  def test_a_tagged_recipient_is_recorded_as_having_matched_by_tag
    ingest("#{WEEKLY.sub('@', '+list@')}", "simple-multipart.eml")

    assert_equal "tag", journal.first["match"]
  end

  # F5 says this address should have been refused at SMTP time, so a line here
  # is evidence that smtpd.conf and feeds.json have drifted apart. Recording
  # the sender and subject is what tells a retired newsletter apart from a
  # stranger guessing addresses — and only one of those is worth acting on.
  def test_a_refused_delivery_is_recorded_with_who_sent_it_although_nothing_is_stored
    code, = ingest("nikt@feeds.lasocha.net", "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_NOUSER, code
    entry = journal.first
    assert_equal "no-feed", entry["outcome"]
    assert_equal Mail2rss26::CLI::EX_NOUSER, entry["exit"]
    assert_equal "nikt@feeds.lasocha.net", entry["recipient"]
    assert_equal "20260812060316.4c1b9a7e@mail.lamplighter.example", entry["message_id"]
    assert_nil entry["feed"]
    assert_nil entry["file"]
    assert_empty stored_state
  end

  # The deferrals are the whole reason this exists. A silently deferring mda
  # line looks exactly like a quiet week with no newsletters, and stderr goes
  # into a mail log that rotates.
  def test_a_deferred_delivery_records_why_even_when_the_feed_list_is_what_broke
    code, = run_cli("ingest", "--recipient", WEEKLY, "--config", File.join(@tmp, "gone.json"),
                    "--state-dir", @state)

    assert_includes DEFERRING, code
    entry = journal.first
    assert_equal "deferred", entry["outcome"]
    assert_equal Mail2rss26::CLI::EX_TEMPFAIL, entry["exit"]
    assert_equal "config", entry["reason"]
    assert_equal WEEKLY, entry["recipient"]
    assert_includes entry["error"], "gone.json"
  end

  def test_a_broken_mda_line_is_recorded_even_though_its_options_never_parsed
    code, = run_cli("ingest", "--recipeint", WEEKLY, "--state-dir", @state)

    assert_includes DEFERRING, code
    assert_equal "usage", journal.first["reason"]
  end

  # `render` is run by systemd, and a systemd unit that fails is visible as a
  # failed unit. Recording it here would put non-deliveries in a log of
  # deliveries for no gain.
  def test_render_writes_nothing_to_the_journal
    run_cli("render", "--config", @config)

    assert_empty journal
  end

  # The rule that matters most, and the one that is easy to get backwards. The
  # message is on disk and the feed is rendered; the note about it could not be
  # written. Deferring here would hand the envelope back to the queue over a
  # bookkeeping failure, and the redelivery would find the message already
  # stored — so the cost of getting this wrong is paid four days later, in
  # confusion, for nothing.
  def test_a_journal_that_cannot_be_written_does_not_fail_the_delivery
    FileUtils.mkdir_p(File.join(@state, Mail2rss26::Journal::DIR))
    FileUtils.chmod(0o500, File.join(@state, Mail2rss26::Journal::DIR))

    code, _out, err = ingest(WEEKLY, "simple-multipart.eml")

    assert_equal Mail2rss26::CLI::EX_OK, code
    assert_equal 1, messages_in("lamplighter").length
    assert_path_exists atom_path("lamplighter")
    assert_includes err, "could not write the delivery journal"
  end

  # N6 is about rendering, and the journal is not part of a render — but it now
  # sits inside the state directory, so it is worth one assertion that it stays
  # out of the way.
  def test_the_journal_does_not_disturb_a_rendered_feed
    ingest(WEEKLY, "simple-multipart.eml")
    before = File.binread(atom_path("lamplighter"))

    ingest(WEEKLY, "simple-multipart.eml")

    assert_equal before, File.binread(atom_path("lamplighter"))
    refute_includes Dir.children(feed_dir("lamplighter")), Mail2rss26::Journal::DIR
  end

  private

  # Everything in the state directory that is a feed rather than the journal —
  # which is what "nothing was written" has always meant and now has to say
  # explicitly.
  def stored_state
    Dir.children(@state) - [Mail2rss26::Journal::DIR]
  end

  # Newest first, the way the viewer reads them.
  def journal
    Mail2rss26::Journal.new(@state).entries
  end

  def ingest(recipient, fixture_name, *extra)
    run_cli("ingest", "--recipient", recipient, "--config", @config, *extra,
            stdin: StringIO.new(File.binread(fixture_path(fixture_name))))
  end

  def run_cli(*argv, stdin: StringIO.new(""))
    out = StringIO.new
    err = StringIO.new
    code = Mail2rss26::CLI.run(argv, stdout: out, stderr: err, stdin: stdin)
    [code, out.string, err.string]
  end

  # bin/mail2rss26 under the interpreter that is running the suite — named
  # explicitly rather than through the shebang, so this works the same in the
  # dev shell and inside the `nix flake check` sandbox.
  def run_binary(*argv, input: "")
    bin = File.expand_path("../bin/mail2rss26", __dir__)
    output = IO.popen([RbConfig.ruby, bin, *argv], "r+", err: %i[child out]) do |io|
      io.binmode
      io.write(input)
      io.close_write
      io.read
    end

    [$?.exitstatus, output]
  end

  def feed_dir(name)
    File.join(@state, name)
  end

  def atom_path(name)
    File.join(feed_dir(name), "atom.xml")
  end

  def messages_in(name)
    Dir.children(feed_dir(name)).grep(/\.eml\z/).sort
  end

  def atom(name)
    REXML::Document.new(File.binread(atom_path(name)))
  end

  def entries_of(doc)
    doc.get_elements("/feed/entry")
  end

  def text_of(element, name)
    child = element&.elements&.[](name)
    child && child.texts.map(&:value).join
  end
end
