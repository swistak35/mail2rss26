# frozen_string_literal: true

require_relative "test_helper"
require "json"

# Phase 4: the feed list, as the NixOS module of Phase 6 will generate it.
#
# This file is where the JSON schema is actually pinned. The README describes
# it in prose; if the two ever disagree, one of them is a lie and this is the
# one a `nix flake check` notices.
class ConfigTest < Minitest::Test
  DOCUMENT = {
    "version" => 1,
    "stateDir" => "/var/lib/mail2rss26",
    "feeds" => {
      "lamplighter" => {
        "title" => "The Lamplighter",
        "id" => "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21",
        "url" => "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom",
        "addresses" => ["weekly.a41f9d@feeds.lasocha.net"]
      },
      "sluice" => {
        "title" => "Sluice Gate Quarterly",
        "id" => "urn:uuid:1f0f2f6c-3c6a-4a3f-9d0b-2a1b8f4c7e35",
        "addresses" => ["sluice.1b9e44@feeds.lasocha.net", "sluice.old@feeds.lasocha.net"]
      }
    }
  }.freeze

  def config(document = DOCUMENT)
    Mail2rss26::Config.parse(JSON.generate(document), "feeds.json")
  end

  # DOCUMENT with one field of one feed changed, so each validation test can
  # name exactly the thing it is breaking.
  def with_feed(name, changes)
    document = Marshal.load(Marshal.dump(DOCUMENT))
    document["feeds"][name] = document["feeds"][name].merge(changes)
    document
  end

  def error(document)
    assert_raises(Mail2rss26::Config::Error) { config(document) }.message
  end

  # --- the shape ------------------------------------------------------------

  def test_a_feed_carries_all_three_tokens_plus_a_name_and_a_title
    feed = config.feed_named("lamplighter")

    assert_equal "lamplighter", feed.name
    assert_equal "The Lamplighter", feed.title
    assert_equal "urn:uuid:6b6c5f2c-9d0e-4a71-8d55-7b1a3e0c4f21", feed.id
    assert_equal "https://feeds.lasocha.net/7c31e9a2b4d8f05e.atom", feed.url
    assert_equal ["weekly.a41f9d@feeds.lasocha.net"], feed.addresses
  end

  # The URL is the rotatable secret and it is the one field a deployment can
  # reasonably not want written into the file nginx serves (F8). Feed already
  # treats self_url as optional; the schema has to agree.
  def test_the_url_is_optional
    assert_nil config.feed_named("sluice").url
  end

  def test_feeds_come_back_in_a_fixed_order
    assert_equal %w[lamplighter sluice], config.feeds.map(&:name)
  end

  def test_the_state_dir_may_come_from_the_config
    assert_equal "/var/lib/mail2rss26", config.state_dir
    assert_nil config(DOCUMENT.reject { |k, _| k == "stateDir" }).state_dir
  end

  # --- recipient -> feed (F5) ----------------------------------------------

  def test_a_configured_address_finds_its_feed
    assert_equal "lamplighter", config.feed_for("weekly.a41f9d@feeds.lasocha.net").name
  end

  def test_a_feed_may_own_several_addresses
    %w[sluice.1b9e44@feeds.lasocha.net sluice.old@feeds.lasocha.net].each do |address|
      assert_equal "sluice", config.feed_for(address).name
    end
  end

  # A feed that is not in the configuration does not exist. No catch-all, ever.
  def test_an_unknown_address_finds_nothing
    assert_nil config.feed_for("weekly.a41f9e@feeds.lasocha.net")
    assert_nil config.feed_for("weekly.a41f9d@lasocha.net")
    assert_nil config.feed_for("weekly.a41f9d")
    assert_nil config.feed_for("")
  end

  def test_matching_ignores_case
    assert_equal "lamplighter", config.feed_for("Weekly.A41F9D@Feeds.Lasocha.NET").name
  end

  def test_matching_ignores_angle_brackets_and_surrounding_space
    assert_equal "lamplighter", config.feed_for("  <weekly.a41f9d@feeds.lasocha.net> ").name
  end

  def test_a_plus_tag_still_reaches_the_feed
    assert_equal "lamplighter", config.feed_for("weekly.a41f9d+bounces@feeds.lasocha.net").name
  end

  # The tag is stripped from the *recipient*, not from the configuration, so a
  # tag cannot conjure a feed that was never configured.
  def test_a_plus_tag_cannot_invent_a_feed
    assert_nil config.feed_for("nobody+weekly.a41f9d@feeds.lasocha.net")
    assert_nil config.feed_for("+weekly.a41f9d@feeds.lasocha.net")
  end

  # OpenSMTPD substitutes ":" for characters it finds suspicious when it expands
  # %{rcpt}. A mangled address must simply not match — which it cannot, because
  # ":" is outside the alphabet a feed address is allowed to use.
  def test_a_recipient_mangled_by_opensmtpd_matches_nothing
    assert_nil config.feed_for("weekly:a41f9d@feeds.lasocha.net")
  end

  # --- validation -----------------------------------------------------------

  def test_a_wrong_or_missing_version_is_refused
    assert_includes error(DOCUMENT.merge("version" => 2)), "version must be 1"
    assert_includes error(DOCUMENT.reject { |k, _| k == "version" }), "version must be 1"
  end

  def test_something_that_is_not_json_is_refused
    e = assert_raises(Mail2rss26::Config::Error) { Mail2rss26::Config.parse("{oops", "feeds.json") }
    assert_includes e.message, "not valid JSON"
  end

  def test_feeds_must_be_an_object_keyed_by_name
    assert_includes error(DOCUMENT.merge("feeds" => [])), "keyed by feed name"
  end

  # A feed name becomes a directory name under the state dir, so the interesting
  # cases are the ones that are not names at all.
  def test_a_feed_name_that_is_not_a_directory_name_is_refused
    ["..", "../etc", ".hidden", "a/b", "", "Weekly"].each do |name|
      document = { "version" => 1, "feeds" => { name => DOCUMENT["feeds"]["lamplighter"] } }
      assert_includes error(document), "not a usable feed name", "feed name #{name.inspect}"
    end
  end

  def test_the_mandatory_fields_are_mandatory
    assert_includes error(with_feed("lamplighter", "title" => nil)), "lamplighter.title"
    assert_includes error(with_feed("lamplighter", "title" => "  ")), "lamplighter.title"
    assert_includes error(with_feed("lamplighter", "id" => nil)), "lamplighter.id"
    assert_includes error(with_feed("lamplighter", "addresses" => [])), "non-empty array"
    assert_includes error(with_feed("lamplighter", "addresses" => "a@b")), "non-empty array"
  end

  def test_an_address_that_is_not_one_is_refused
    ["not-an-address", "two@at@signs", "with space@feeds.lasocha.net", "<a@b>"].each do |address|
      assert_includes error(with_feed("lamplighter", "addresses" => [address])), "not a usable address"
    end
  end

  # Two feeds claiming one address is not a preference we can guess at, and
  # guessing files someone's newsletter in the wrong place forever.
  def test_an_address_claimed_by_two_feeds_is_refused
    document = with_feed("sluice", "addresses" => ["weekly.a41f9d@feeds.lasocha.net"])

    assert_includes error(document), "claimed by both"
  end

  # --- where the file comes from -------------------------------------------

  def test_the_config_path_prefers_the_flag_then_the_environment
    with_env("MAIL2RSS26_CONFIG" => "/from/env.json") do
      assert_equal "/from/flag.json", Mail2rss26::Config.path("/from/flag.json")
      assert_equal "/from/env.json", Mail2rss26::Config.path(nil)
    end

    with_env("MAIL2RSS26_CONFIG" => "") do
      assert_equal Mail2rss26::Config::DEFAULT_PATH, Mail2rss26::Config.path(nil)
    end

    with_env("MAIL2RSS26_CONFIG" => nil) do
      assert_equal Mail2rss26::Config::DEFAULT_PATH, Mail2rss26::Config.path(nil)
    end
  end

  private

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
