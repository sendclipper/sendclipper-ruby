# frozen_string_literal: true

require_relative "lib/sendclipper/version"

Gem::Specification.new do |spec|
  spec.name = "sendclipper"
  spec.version = SendClipper::VERSION
  spec.authors = ["SendClipper"]
  spec.email = ["support@sendclipper.com"]
  spec.summary = "Official Ruby SDK for the SendClipper email API."
  spec.description = "Send mail, and manage domains, templates, sandboxes, webhooks, contacts and suppressions " \
                     "with the SendClipper email API. No runtime dependencies."
  spec.homepage = "https://sendclipper.com/docs#sdk-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  spec.metadata = {
    "homepage_uri" => spec.homepage,
    "source_code_uri" => "https://github.com/sendclipper/sendclipper-ruby",
    "bug_tracker_uri" => "https://github.com/sendclipper/sendclipper-ruby/issues",
    "changelog_uri" => "https://github.com/sendclipper/sendclipper-ruby/blob/main/CHANGELOG.md",
    "documentation_uri" => "https://sendclipper.com/docs#sdk-ruby",
    "rubygems_mfa_required" => "true"
  }

  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
