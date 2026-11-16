# frozen_string_literal: true

require "bard/api"
require "bard/backup"
require "rack/test"

TEST_PRIVATE_KEY = OpenSSL::PKey::RSA.new(2048)

RSpec.configure do |config|
  config.before { stub_const("Bard::Api::Auth::BARD_PUBLIC_KEY", TEST_PRIVATE_KEY.public_key) }

  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  # Include Rack::Test::Methods for API testing
  config.include Rack::Test::Methods
end
