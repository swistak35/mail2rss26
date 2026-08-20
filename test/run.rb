# frozen_string_literal: true

# Runs the whole suite. Used by `nix flake check` and by `make test`; there is no
# Rakefile because rake would be a second thing to package for no gain.
require_relative "test_helper"

Dir[File.expand_path("**/*_test.rb", __dir__)].sort.each { |f| require f }
