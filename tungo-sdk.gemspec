# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "tungo-sdk"
  spec.version = "0.3.0" # x-release-version
  spec.authors = ["Tungo"]
  spec.summary = "Official Ruby library for the Tungo Platform API"
  spec.description = "Typed client for the Tungo Platform API: AI accountant chat with streaming, " \
                     "proposals, automations, webhooks. Generated from the API's OpenAPI contract."
  spec.homepage = "https://github.com/TungoAI/tungo-sdk-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "sig/**/*.rbs", "sig/manifest.yaml", "README.md", "CHANGELOG.md", "LICENSE",
                   "SECURITY.md"]
  spec.require_paths = ["lib"]

  # Default gems that newer Rubies only load when they are declared.
  spec.add_dependency "base64", ">= 0.1", "< 1"
  spec.add_dependency "bigdecimal", ">= 3.1", "< 5"
end
