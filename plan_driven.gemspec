# frozen_string_literal: true

require_relative "lib/plan_driven/version"

Gem::Specification.new do |spec|
  spec.name = "plan_driven"
  spec.version = PlanDriven::VERSION
  spec.authors = ["Ivan Blažević"]
  spec.email = ["ivan.blazevic@rubycode.co"]

  spec.summary = "From implementation plan to merged, tested pull requests, driven from the browser or the terminal."
  spec.description = <<~DESC
    plan_driven runs a Rails team's delivery process inside your Rails app, from a browser wizard
    or the command line: every button in the wizard runs the same plan-driven command. A short
    interview turns an idea into an implementation plan grounded in your real schema; the plan
    is checked by guards written in Ruby, rendered to PDF and approved. Approved plans become tickets, each
    ticket is handed to a Cursor cloud agent that opens a pull request, and only pull requests
    you approve are merged. Acceptance criteria map to Cucumber scenarios, and every phase leaves
    documentation behind: the plan, the tickets, the pull requests and a delivery report.
  DESC
  spec.homepage = "https://github.com/blaz1988/plan-driven"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["documentation_uri"] = "#{spec.homepage}#readme"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.{rb,css,tt,mjs}", "app/**/*.{rb,erb}", "config/routes.rb", "exe/*",
                   "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["plan-driven"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.0", "< 9"
  spec.add_dependency "railties", ">= 7.0", "< 9"
end
