# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "securerandom"
require "shellwords"

module PlanDriven
  # The browser wizard at /plan_driven. Every button runs a real `plan-driven` command in the
  # background and streams its output to the page, so the wizard can do nothing the CLI can't,
  # and the terminal panel shows exactly which command ran.
  module Wizard
    # The commands the wizard may run, built from form fields. Nothing else reaches a shell:
    # arguments are passed as an array, never interpolated.
    module Commands
      PLAN_ONLY = %w[check submit pdf status evidence report usage log].freeze

      BUILDERS = {
        "doctor" => ->(_p) { [] },
        "new" => ->(p) { [required(p, "title")] },
        "edit" => ->(p) { [plan(p), section(p), "--from", required(p, "file")] },
        "redraft" => ->(p) { [plan(p), section(p), required(p, "instruction")] },
        "approve" => ->(p) { [plan(p), *role(p), *note(p)] },
        "reject" => ->(p) { [plan(p), *role(p), "--note", required(p, "note")] },
        "tickets" => ->(p) { [plan(p), *p["instruction"].to_s.strip.presence] },
        "approve-tickets" => ->(p) { [plan(p), *role(p)] },
        "develop" => ->(p) { [plan(p), *Array(p["tickets"]).map { |key| ticket_key(key) }] },
        "review" => ->(p) { [ticket(p)] },
        "merge" => ->(p) { [ticket(p)] },
        "approve-pr" => ->(p) { [ticket(p), *note(p)] },
        "feedback" => ->(p) { [ticket(p), required(p, "feedback")] }
      }.merge(PLAN_ONLY.to_h { |name| [name, ->(p) { [plan(p)] }] }).freeze

      module_function

      def argv(action, params)
        builder = BUILDERS[action.to_s] or raise ArgumentError, "the wizard can't run `#{action}`"
        [action.to_s, *builder.call(params.to_h.transform_keys(&:to_s)), "--yes"]
      end

      # What `new` reads on stdin. The interview takes each answer up to an empty line, so blank
      # lines inside an answer are folded away, and an empty answer is the empty line alone.
      def interview_input(template, answers)
        template.asked.map do |section|
          answer = answers[section.key].to_s.strip.gsub(/\r\n?/, "\n").gsub(/\n\s*\n+/, "\n")
          answer.empty? ? "\n" : "#{answer}\n\n"
        end.join
      end

      def required(params, name)
        params[name].to_s.strip.presence or raise ArgumentError, "#{name.tr("_", " ")} is required"
      end

      def plan(params)
        key = required(params, "plan").upcase
        raise ArgumentError, "not a plan key" unless key.match?(/\A[A-Z]+-\d+\z/)

        key
      end

      def ticket(params)
        "#{plan(params)}/#{ticket_key(required(params, "ticket"))}"
      end

      def ticket_key(key)
        key.to_s.upcase.tap { |value| raise ArgumentError, "not a ticket key" unless value.match?(/\AT\d+\z/) }
      end

      def section(params)
        key = required(params, "section")
        PlanDriven.configuration.template[key] or raise ArgumentError, "unknown section #{key}"
        key
      end

      def role(params)
        params["role"].to_s.strip.empty? ? [] : ["--as", params["role"].strip]
      end

      def note(params)
        params["note"].to_s.strip.empty? ? [] : ["--note", params["note"].strip]
      end
    end

    # One command run: its output in a log file, its state in a JSON file next to it, so any
    # request (and any Puma thread) can read how it's going.
    class Job
      attr_reader :id

      def self.dir(root = PlanDriven.configuration.root_path)
        root.join("tmp/plan_driven/wizard").tap { |path| FileUtils.mkdir_p(path) }
      end

      def self.find(id, root: PlanDriven.configuration.root_path)
        raise ArgumentError, "not a job" unless id.to_s.match?(/\A[a-f0-9]{16}\z/)

        new(id, root: root).tap { |job| raise ArgumentError, "no job #{id}" unless job.state_file.exist? }
      end

      # Starts `argv` in a thread and returns at once.
      def self.start(argv, stdin: nil, actor: nil, root: PlanDriven.configuration.root_path)
        job = new(SecureRandom.hex(8), root: root)
        job.begin!(argv, stdin: stdin, actor: actor)
        job
      end

      def initialize(id, root:)
        @id = id
        @root = Pathname(root)
      end

      def begin!(argv, stdin:, actor:)
        command = executable + argv
        write_state("command" => display(command, actor), "status" => "running", "started_at" => Time.now.to_i)
        File.write(log_file, "")
        Thread.new { execute(command, stdin, actor) }
      end

      def state
        JSON.parse(state_file.read)
      end

      def output
        log_file.exist? ? log_file.read.force_encoding(Encoding::UTF_8).scrub : ""
      end

      def to_h
        state.merge("id" => id, "output" => output)
      end

      def state_file
        self.class.dir(@root).join("#{id}.json")
      end

      def log_file
        self.class.dir(@root).join("#{id}.log")
      end

      private

      def execute(command, stdin, actor)
        env = { "LANG" => "en_US.UTF-8", "LC_ALL" => "en_US.UTF-8", "NO_COLOR" => "1" }
        env["PLAN_DRIVEN_ACTOR"] = actor if actor.present?
        status = Open3.popen2e(env, *command, chdir: @root.to_s) do |input, output, thread|
          input.write(stdin.to_s)
          input.close
          File.open(log_file, "a") do |log|
            output.each_char do |char|
              log.write(char)
              log.flush if char == "\n"
            end
          end
          thread.value
        end
        finish(status.exitstatus)
      rescue StandardError => e
        File.write(log_file, "\n✗ #{e.message}\n", mode: "a")
        finish(1)
      end

      def finish(code)
        write_state(state.merge("status" => code.to_i.zero? ? "succeeded" : "failed", "exit" => code,
                                "finished_at" => Time.now.to_i))
      end

      def write_state(data)
        File.write(state_file, JSON.generate(data))
      end

      def executable
        binstub = @root.join("bin/plan-driven")
        binstub.exist? ? ["bin/plan-driven"] : %w[bundle exec plan-driven]
      end

      def display(command, actor)
        prefix = actor.present? ? "PLAN_DRIVEN_ACTOR=#{Shellwords.escape(actor)} " : ""
        shown = command.map { |arg| arg.start_with?(@root.to_s) ? arg.delete_prefix("#{@root}/") : arg }
        prefix + Shellwords.join(shown)
      end
    end

    # The wizard's pages, in order, and which ones a plan in a given phase has reached.
    module Steps
      ORDER = [
        ["plan", "Plan", "Read it, edit or redraft any section, then submit"],
        ["approve", "Approve", "Every role signs off on this revision"],
        ["tickets", "Tickets", "Draft the tickets, steer them, approve them"],
        ["agents", "Agents & PRs", "One agent and one pull request per ticket"],
        ["finish", "Proof & report", "Evidence, the delivery report, tokens and cost"]
      ].freeze

      REACHED = {
        "draft" => "plan", "in_review" => "approve", "approved" => "tickets", "ticketed" => "tickets",
        "tickets_approved" => "agents", "in_development" => "agents", "delivered" => "finish"
      }.freeze

      module_function

      def keys
        ORDER.map(&:first)
      end

      def current(plan)
        REACHED.fetch(plan.status, "plan")
      end

      def reached?(plan, step)
        keys.index(step).to_i <= keys.index(current(plan)).to_i
      end
    end
  end
end

if defined?(Rails::Railtie)
  require "rails/engine"
  require_relative "wizard/engine"
end
