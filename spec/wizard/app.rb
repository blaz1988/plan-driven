# frozen_string_literal: true

# A minimal Rails app with the wizard mounted, run in its own process by wizard_engine_spec.rb
# so the rest of the suite stays free of Rails. Prints one line per request: status, path, and
# whether the page has what it should.
require "bundler/setup"
require "logger"
require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "plan_driven"

class WizardApp < Rails::Application
  config.load_defaults Rails::VERSION::STRING.to_f
  config.root = ENV.fetch("APP_ROOT")
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.secret_key_base = "0" * 64
  config.hosts.clear if config.respond_to?(:hosts)
  config.active_support.deprecation = :silence
  routes.append { mount PlanDriven::Wizard::Engine, at: "/plan_driven" }
end

ENV["DATABASE_URL"] = "sqlite3::memory:"
Rails.application.initialize!
ActiveRecord::Migration.verbose = false
template = File.read(File.expand_path("../../lib/generators/plan_driven/templates/create_plan_driven_tables.rb.tt",
                                      __dir__))
eval(template.sub("<%= ActiveRecord::Migration.current_version %>", ActiveRecord::Migration.current_version.to_s)) # rubocop:disable Security/Eval
CreatePlanDrivenTables.migrate(:up)

PlanDriven.configure { |c| c.wizard_enabled = true }
plan = PlanDriven::Plan.create!(title: "Event categories", sections: { "what" => "Organizers pick a **category**." },
                                guard_report: { "errors" => ["What is too short"], "passes" => ["Who is set"] })
plan.tickets.create!(key: "T1", title: "Migration: Create categories", status: "pr_open", pr_url: "https://x/pr/1",
                     pr_number: 1, acceptance_criteria: ["categories exist"])

app = Rack::MockRequest.new(Rails.application)
local = { "REMOTE_ADDR" => "127.0.0.1" }
checks = {
  "/plan_driven" => ["PD-1", "Check the setup"],
  "/plan_driven/plans/new" => ["What are we building?", "Draft the plan", "earlier decisions (optional)"],
  "/plan_driven/configuration" => ["Connections", "Paste the Cursor key", "Interview questions", "Add a question",
                                   "config/plan_driven/interview.yml"],
  "/plan_driven/plans/PD-1" => ["<strong>category</strong>", "What is too short", "Run the guards"],
  "/plan_driven/plans/PD-1/approve" => ["review", "submit it on the Plan step"],
  "/plan_driven/plans/PD-1/tickets" => ["Migration: Create categories", "categories exist"],
  "/plan_driven/plans/PD-1/agents" => ["PR #1", "Approve PR"],
  "/plan_driven/plans/PD-1/finish" => ["Write the delivery report"],
  "/plan_driven/jobs/0000000000000000" => ["no job"]
}
checks.each do |path, texts|
  response = app.get(path, local)
  puts "#{response.status} #{path} #{texts.all? { |text| response.body.include?(text) }}"
end
puts "#{app.get("/plan_driven", "REMOTE_ADDR" => "10.0.0.5").status} remote"
