# frozen_string_literal: true

require_relative "lib/logrift/version"

Gem::Specification.new do |spec|
  spec.name = "logrift"
  spec.version = Logrift::VERSION
  spec.authors = ["Logrift"]
  spec.summary = "Ruby client and Rails logger for Logrift"
  spec.description = "Send structured logs to a self-hosted Logrift server from Ruby and Rails."
  spec.homepage = "https://github.com/logrift/ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.add_dependency "json", ">= 2.6", "< 3"
  spec.add_dependency "logger", ">= 1.5", "< 2"
  spec.add_dependency "net-http", ">= 0.3", "< 1"
end
