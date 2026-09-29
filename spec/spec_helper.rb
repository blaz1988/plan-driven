# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "plan_driven"
require "plan_driven/cli"
require "stringio"
require "tmpdir"
require "fileutils"

Dir[File.join(__dir__, "support", "*.rb")].each { |file| require file }

RSpec::Matchers.define_negated_matcher :not_include, :include

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  config.warnings = false
  Kernel.srand config.seed

  config.include Fixtures

  config.around do |example|
    Dir.mktmpdir do |dir|
      previous = ENV.fetch("PLAN_DRIVEN_CREDENTIALS", nil)
      ENV["PLAN_DRIVEN_CREDENTIALS"] = File.join(dir, "credentials")
      @root = Pathname(dir)
      FileUtils.mkdir_p(@root.join("app/models"))
      %w[form field business_process project].each { |name| FileUtils.touch(@root.join("app/models/#{name}.rb")) }
      PlanDriven.configure do |c|
        c.root = @root
        c.github_repository = "acme/app"
        c.pdf_renderer = ->(_html, _pdf) { false }
      end
      example.run
    ensure
      ENV["PLAN_DRIVEN_CREDENTIALS"] = previous
    end
  end

  config.before do
    TestDatabase.clean!
    PlanDriven::HTTP.reset!
  end

  config.after do
    PlanDriven.reset!
    PlanDriven::HTTP.reset!
  end
end
