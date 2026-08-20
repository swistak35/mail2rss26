# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "mail2rss26"

module Mail2rss26
  module TestHelper
    FIXTURES = File.expand_path("fixtures", __dir__)

    # The fixture set is the real specification of this program: every newsletter
    # that breaks it lands here next to the fix.
    def fixture_path(name)
      File.join(FIXTURES, name)
    end

    def fixture(name)
      File.read(fixture_path(name))
    end

    # The parsed form of the same thing (not `message`: Minitest already has
    # one, and shadowing it turns every assertion message into a stack trace).
    # Fixtures are read as bytes, the way
    # OpenSMTPD will hand them over: a fixture whose declared charset is a lie
    # must not become a different lie on the way into the test.
    def parsed_fixture(name)
      Mail2rss26::Message.parse(File.binread(fixture_path(name)))
    end
  end
end

Minitest::Test.include(Mail2rss26::TestHelper)
