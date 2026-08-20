# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

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

  # Not implemented still means non-zero: nothing in this program is allowed to
  # answer "fine" when it did not deliver (N3).
  def test_ingest_is_wired_up_but_not_implemented
    code, _out, err = run_cli("ingest", "--recipient", "weekly.a41f9d@feeds.lasocha.net",
                              stdin: StringIO.new(fixture("simple-multipart.eml")))
    assert_equal Mail2rss26::CLI::EX_NOT_IMPLEMENTED, code
    refute_equal 0, code
    assert_includes err, "not implemented"
  end

  def test_render_is_wired_up_but_not_implemented
    code, _out, err = run_cli("render", "--feed", "weekly")
    assert_equal Mail2rss26::CLI::EX_NOT_IMPLEMENTED, code
    assert_includes err, "not implemented"
  end
end
