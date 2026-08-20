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

  def test_no_arguments_is_a_usage_error
    code, out, _err = run_cli
    assert_equal Mail2rss26::CLI::EX_USAGE, code
    assert_includes out, "Usage: mail2rss26"
  end

  def test_unknown_command_is_a_usage_error
    code, _out, err = run_cli("digest")
    assert_equal Mail2rss26::CLI::EX_USAGE, code
    assert_includes err, "unknown command"
  end

  def test_ingest_requires_a_recipient
    code, _out, err = run_cli("ingest")
    assert_equal Mail2rss26::CLI::EX_USAGE, code
    assert_includes err, "--recipient is required"
  end

  def test_an_unknown_option_is_a_usage_error
    code, _out, err = run_cli("ingest", "--recipient", "a@b", "--verbose")
    assert_equal Mail2rss26::CLI::EX_USAGE, code
    assert_includes err, "invalid option"
  end

  # The contract, as constants. The numbers are sysexits(3) values and the
  # README table is written against exactly these — a change here is a change to
  # the interface with OpenSMTPD, so it should have to walk past this test.
  def test_the_exit_codes_are_the_sysexits_numbers
    assert_equal 0, Mail2rss26::CLI::EX_OK
    assert_equal 64, Mail2rss26::CLI::EX_USAGE
    assert_equal 65, Mail2rss26::CLI::EX_DATAERR
    assert_equal 67, Mail2rss26::CLI::EX_NOUSER
    assert_equal 70, Mail2rss26::CLI::EX_SOFTWARE
    assert_equal 74, Mail2rss26::CLI::EX_IOERR
    assert_equal 75, Mail2rss26::CLI::EX_TEMPFAIL
    assert_equal 78, Mail2rss26::CLI::EX_CONFIG
  end

  # Both commands need the feed list before they can do anything at all, and a
  # missing one is an operator problem rather than an I/O hiccup (EX_CONFIG, not
  # EX_IOERR) — retrying the delivery cannot conjure the file.
  def test_a_missing_config_is_a_config_error_for_ingest
    code, _out, err = run_cli("ingest", "--recipient", "weekly.a41f9d@feeds.lasocha.net",
                              "--config", "/nonexistent-config-for-mail2rss26.json",
                              stdin: StringIO.new(fixture("simple-multipart.eml")))
    assert_equal Mail2rss26::CLI::EX_CONFIG, code
    assert_includes err, "cannot read config"
  end

  def test_a_missing_config_is_a_config_error_for_render
    code, _out, err = run_cli("render", "--config", "/nonexistent-config-for-mail2rss26.json")
    assert_equal Mail2rss26::CLI::EX_CONFIG, code
    assert_includes err, "cannot read config"
  end

  def test_version_and_help_are_the_only_things_that_exit_zero_without_working
    assert_equal Mail2rss26::CLI::EX_OK, run_cli("--version").first
    assert_equal Mail2rss26::CLI::EX_OK, run_cli("help").first
  end
end
