# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

# The argument plumbing and the exit-code contract at its edges. What the
# commands actually *do* is ingest_test.rb, against a real directory.
class CLITest < Minitest::Test
  def run_cli(*argv, stdin: StringIO.new(""))
    out = StringIO.new
    err = StringIO.new
    code = Mail2rss26::CLI.run(argv, stdout: out, stderr: err, stdin: stdin)
    [code, out.string, err.string]
  end

  # The numbers OpenSMTPD reads as "keep this envelope and try again": 71
  # (EX_OSERR) and 75 (EX_TEMPFAIL), and nothing else — smtpd.c, and the README.
  # Written as a set rather than as `75` so that these tests assert the
  # *property* N3 asks for and not the particular number that satisfies it
  # today.
  DEFERRING = [71, 75].freeze

  # A broken mda(8) line is a real newsletter and a fixable mistake, so it has
  # to defer: the operator edits smtpd.conf and the queue delivers what it was
  # holding. It used to answer 64, which bounced.
  def test_no_arguments_defers_rather_than_bouncing
    code, out, _err = run_cli
    assert_includes DEFERRING, code
    assert_includes out, "Usage: mail2rss26"
  end

  def test_an_unknown_command_defers_rather_than_bouncing
    code, _out, err = run_cli("digest")
    assert_includes DEFERRING, code
    assert_includes err, "unknown command"
  end

  def test_ingest_requires_a_recipient
    code, _out, err = run_cli("ingest")
    assert_includes DEFERRING, code
    assert_includes err, "--recipient is required"
  end

  def test_an_unknown_option_defers_rather_than_bouncing
    code, _out, err = run_cli("ingest", "--recipient", "a@b", "--verbose")
    assert_includes DEFERRING, code
    assert_includes err, "invalid option"
  end

  # The contract, as constants. Three codes, because smtpd only understands two
  # answers and success is the third — the sysexits(3) vocabulary is on stderr
  # instead. A change here is a change to the interface with OpenSMTPD, so it
  # should have to walk past this test.
  def test_the_contract_is_three_numbers
    assert_equal 0, Mail2rss26::CLI::EX_OK
    assert_equal 67, Mail2rss26::CLI::EX_NOUSER
    assert_equal 75, Mail2rss26::CLI::EX_TEMPFAIL

    # The codes this program used to return and deliberately no longer does.
    # Every one of them is a MDA_PERMFAIL to smtpd, so every one of them threw
    # a newsletter away. If a constant with one of these names comes back, the
    # question it has to answer first is which delivery it is prepared to lose.
    %w[EX_USAGE EX_DATAERR EX_SOFTWARE EX_IOERR EX_CONFIG].each do |name|
      refute Mail2rss26::CLI.const_defined?(name, false), "#{name} is back"
    end
  end

  # Both commands need the feed list before they can do anything at all. It is
  # an operator problem, which is exactly why it defers: the file gets fixed and
  # the queue drains. (Under the old contract this answered 78 and bounced every
  # newsletter that arrived during a bad deploy.)
  def test_a_missing_config_defers_for_ingest
    code, _out, err = run_cli("ingest", "--recipient", "weekly.a41f9d@feeds.lasocha.net",
                              "--config", "/nonexistent-config-for-mail2rss26.json",
                              stdin: StringIO.new(fixture("simple-multipart.eml")))
    assert_includes DEFERRING, code
    assert_includes err, "cannot read config"
  end

  def test_a_missing_config_defers_for_render
    code, _out, err = run_cli("render", "--config", "/nonexistent-config-for-mail2rss26.json")
    assert_includes DEFERRING, code
    assert_includes err, "cannot read config"
  end

  def test_version_and_help_are_the_only_things_that_exit_zero_without_working
    assert_equal Mail2rss26::CLI::EX_OK, run_cli("--version").first
    assert_equal Mail2rss26::CLI::EX_OK, run_cli("help").first
  end
end
