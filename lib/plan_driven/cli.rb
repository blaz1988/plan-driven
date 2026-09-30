# frozen_string_literal: true

require "optparse"
require "tempfile"

require_relative "cli/ui"
require_relative "cli/plan_commands"
require_relative "cli/ticket_commands"
require_relative "cli/setup_commands"
require_relative "cli/config_commands"

module PlanDriven
  # bundle exec plan-driven <command> [arguments]
  class CLI
    include PlanCommands
    include TicketCommands
    include SetupCommands
    include ConfigCommands

    COMMANDS = {
      "new" => ["TITLE", "Interview in the terminal, then draft the plan from your answers and the schema"],
      "list" => ["", "Every plan and its phase"],
      "show" => ["PLAN", "Print the plan, or one section with --section"],
      "edit" => ["PLAN SECTION", "Edit a section in $EDITOR, or replace it with --from FILE"],
      "redraft" => ["PLAN SECTION \"instruction\"", "Have the model rewrite one section"],
      "check" => ["PLAN", "Run the plan guards"],
      "submit" => ["PLAN", "Send the plan for approval (guards must pass)"],
      "approve" => ["PLAN", "Approve the plan (--as ROLE, --note)"],
      "reject" => ["PLAN", "Send the plan back with --note (--as ROLE)"],
      "pdf" => ["PLAN", "Write the plan to docs/plans as Markdown, HTML and PDF"],
      "tickets" => ["PLAN [\"instruction\"]", "Draft tickets from the approved plan, or redraft them"],
      "approve-tickets" => ["PLAN", "Approve the tickets (--as ROLE); creates GitHub issues"],
      "prompt" => ["PLAN/TICKET", "Show what the agent will be told"],
      "develop" => ["PLAN [TICKET...]", "Hand ready tickets to the coding agents (Cursor cloud, or local)"],
      "status" => ["PLAN", "Poll agents and pull requests, then show every ticket"],
      "review" => ["PLAN/TICKET", "Run the pull request guards"],
      "approve-pr" => ["PLAN/TICKET", "Approve the pull request (guards must pass)"],
      "feedback" => ["PLAN/TICKET \"text\"", "Send review feedback to the ticket's agent"],
      "merge" => ["PLAN/TICKET", "Merge an approved pull request"],
      "evidence" => ["PLAN", "Run the plan's Cucumber scenarios and record the results (--from FILE)"],
      "report" => ["PLAN", "Write the delivery report"],
      "log" => ["PLAN", "The audit trail"],
      "usage" => ["PLAN", "Tokens and cost per step and per agent run"],
      "questions" => ["", "The interview's questions, with the team's changes"],
      "question" => ["KEY", "Change or add a question (--title, --ask, --group, --required, --optional, --remove)"],
      "configure" => ["", "Store API keys in ~/.plan_driven/config"],
      "connect" => ["SERVICE", "Check a key with cursor, openai, anthropic or github, then store it"],
      "doctor" => ["", "Check keys, repository and connections"]
    }.freeze

    NO_APP = %w[configure connect doctor help version].freeze

    # Plans are UTF-8 whatever the terminal's locale says, so answers typed with č or ž under
    # LANG=C are read as text, not bytes.
    def self.start(argv, **options)
      Encoding.default_external = Encoding::UTF_8
      new(**options).run(argv.map { |arg| PlanDriven.utf8(arg) })
    end

    def initialize(input: $stdin, output: $stdout, delivery: nil, boot: true)
      @input = input
      @output = output
      @delivery = delivery
      @boot = boot
    end

    def run(argv)
      options = parse_options(argv)
      command = argv.shift || "help"
      @ui = UI.new(input: @input, output: @output, assume_yes: options[:yes])
      @options = options
      return help if %w[help -h --help].include?(command)
      return @ui.say(PlanDriven::VERSION) || 0 if %w[version -v --version].include?(command)
      raise Error, "Unknown command `#{command}`. `plan-driven help` lists them." unless COMMANDS.key?(command)

      boot_application unless NO_APP.include?(command)
      public_send("cmd_#{command.tr("-", "_")}", *argv)
      0
    rescue GuardError => e
      ui.error "Blocked by #{e.problems.size} problem(s):"
      e.problems.each { |problem| ui.say "  - #{problem}" }
      1
    rescue Error, ActiveRecord::RecordNotFound, ArgumentError => e
      ui.error e.message
      1
    end

    def ui
      @ui ||= UI.new(input: @input, output: @output)
    end

    def help
      ui.say "plan-driven #{PlanDriven::VERSION}: from implementation plan to merged, tested pull requests"
      ui.say
      ui.say "Usage: bundle exec plan-driven COMMAND [ARGS] [--yes]"
      ui.say
      width = COMMANDS.map { |name, (args, _)| "#{name} #{args}".length }.max
      COMMANDS.each { |name, (args, text)| ui.say "  #{"#{name} #{args}".ljust(width)}  #{text}" }
      ui.say
      ui.say "Phases: plan draft -> in review -> approved -> tickets -> tickets approved -> in development -> delivered"
      0
    end

    private

    def delivery
      @delivery ||= Delivery.new
    end

    def parse_options(argv)
      options = {}
      OptionParser.new do |parser|
        parser.on("--as ROLE") { |value| options[:role] = value }
        parser.on("--note TEXT") { |value| options[:note] = value }
        parser.on("--section KEY") { |value| options[:section] = value }
        parser.on("--from FILE") { |value| options[:from] = value }
        parser.on("-y", "--yes") { options[:yes] = true }
        question_options(parser, options)
      end.parse!(argv)
      options
    end

    def question_options(parser, options)
      parser.on("--title TEXT") { |value| options[:title] = value }
      parser.on("--ask TEXT") { |value| options[:ask] = value }
      parser.on("--group NAME") { |value| options[:group] = value }
      parser.on("--required") { options[:required] = true }
      parser.on("--optional") { options[:required] = false }
      parser.on("--remove") { options[:remove] = true }
    end

    def boot_application
      return unless @boot
      return if defined?(Rails) && Rails.respond_to?(:application) && Rails.application&.initialized?

      environment = File.expand_path("config/environment.rb", Dir.pwd)
      unless File.exist?(environment)
        raise Error,
              "Run plan-driven from the root of a Rails application (no config/environment.rb here)."
      end

      require environment
      return if ActiveRecord::Base.connection.table_exists?("plan_driven_plans")

      raise Error, "The plan_driven tables are missing. Run `bin/rails generate plan_driven:install` " \
                   "and `bin/rails db:migrate`."
    end

    def find_plan(reference)
      raise ArgumentError, "Which plan? Pass its key, for example PD-1." if reference.to_s.empty?

      Plan.find_by_reference!(reference.to_s.split("/").first)
    end

    def find_ticket(reference)
      plan_key, ticket_key = reference.to_s.split("/")
      raise ArgumentError, "Pass a ticket as PLAN/TICKET, for example PD-1/T2." unless ticket_key

      find_plan(plan_key).ticket!(ticket_key)
    end

    def show_paths(paths)
      paths.compact.each { |path| ui.muted "  #{path.relative_path_from(PlanDriven.configuration.root_path)}" }
    end
  end
end
