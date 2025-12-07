# frozen_string_literal: true

require_relative "lib/bard/api/version"

Gem::Specification.new do |spec|
  spec.name = "bard-api"
  spec.version = Bard::Api::VERSION
  spec.authors = ["Micah Geisel"]
  spec.email = ["micah@botandrose.com"]

  spec.summary = "REST API for BARD-managed Rails projects"
  spec.description = "Rack app that mounts in Rails projects to expose management endpoints for BARD Tracker"
  spec.homepage = "https://github.com/botandrose/bard-api"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/botandrose/bard-api"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git appveyor Gemfile])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Dependencies
  spec.add_dependency "jwt"
  spec.add_dependency "rack"
  spec.add_dependency "backhoe"

  # Development dependencies
  spec.add_development_dependency "rack-test"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
