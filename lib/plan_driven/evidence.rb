# frozen_string_literal: true

require "open3"
require "tmpdir"

module PlanDriven
  # Proof that the delivered code does what the plan promised: every acceptance criterion maps to
  # a Cucumber scenario tagged `@<plan>-<ticket> @ac-N`, and the scenarios' results are stored with
  # the commit they ran against.
  module Evidence
    Row = Struct.new(:ticket, :number, :criterion, :scenarios, keyword_init: true) do
      def status
        return "no scenario" if scenarios.empty?
        return "passed" if scenarios.all? { |scenario| scenario["status"] == "passed" }

        scenarios.any? { |scenario| scenario["status"] == "failed" } ? "failed" : "not run"
      end
    end

    # Scenarios commit and wipe data, so they never run against the development database, even
    # when plan-driven itself was started from a development server (the wizard).
    CUCUMBER_ENV = { "RAILS_ENV" => "test", "RACK_ENV" => "test" }.freeze

    # Shown before each result in the Markdown report, so it reads at a glance on GitHub too.
    MARKS = { "passed" => "✅", "failed" => "❌", "not run" => "⏸️", "no scenario" => "⚠️" }.freeze

    module_function

    def tag_expression(plan)
      plan.tickets.map(&:feature_tag).join(" or ")
    end

    def run_cucumber(plan, actor:, command: nil, root: PlanDriven.configuration.root_path)
      Dir.mktmpdir do |dir|
        out = File.join(dir, "cucumber.json")
        shown = command&.join(" ") || %(bundle exec cucumber --tags "#{tag_expression(plan)}")
        command ||= ["bundle", "exec", "cucumber", "--tags", tag_expression(plan), "--format", "json", "--out", out,
                     "--format", "progress"]
        output, status = Open3.capture2e(CUCUMBER_ENV, *command, chdir: root.to_s)
        json = File.exist?(out) ? File.read(out) : "[]"
        record(plan, json, command: shown, actor: actor, exit_ok: status.success?, output: output)
      end
    end

    def record(plan, json, command:, actor:, exit_ok: true, output: nil)
      scenarios = parse(json)
      status = if scenarios.empty? then "no scenarios"
               elsif exit_ok && scenarios.all? { |scenario| scenario["status"] == "passed" } then "passed"
               else "failed"
               end
      run = plan.evidence_runs.create!(kind: "cucumber", command: command, status: status,
                                       commit_sha: Repository.head_sha,
                                       results: { "scenarios" => scenarios, "output" => output.to_s.last(4000) })
      plan.log!("evidence.recorded", actor: actor, status: status, scenarios: scenarios.size)
      run
    end

    # Cucumber's JSON formatter: features -> elements (scenarios) -> steps with results.
    def parse(json)
      Array(JSON.parse(json.to_s.strip.empty? ? "[]" : json)).flat_map do |feature|
        feature_tags = Array(feature["tags"]).map { |tag| tag["name"] }
        Array(feature["elements"]).select { |element| element["type"] == "scenario" }.map do |element|
          tags = (feature_tags + Array(element["tags"]).map { |tag| tag["name"] }).uniq
          { "name" => element["name"], "tags" => tags, "file" => "#{feature["uri"]}:#{element["line"]}",
            "status" => scenario_status(element) }
        end
      end
    rescue JSON::ParserError
      []
    end

    def scenario_status(element)
      statuses = (Array(element["before"]) + Array(element["steps"]) + Array(element["after"]))
                 .map { |step| step.dig("result", "status") }
      return "failed" if statuses.include?("failed")
      return "passed" if statuses.any? && statuses.all? { |status| %w[passed skipped].include?(status) } &&
                         Array(element["steps"]).all? { |step| step.dig("result", "status") == "passed" }

      "not run"
    end

    def matrix(plan, run = plan.evidence_runs.last)
      scenarios = run&.scenarios || []
      plan.tickets.flat_map do |ticket|
        ticket.criteria.each_with_index.map do |criterion, index|
          matching = scenarios.select do |scenario|
            scenario["tags"].include?(ticket.feature_tag) && scenario["tags"].include?("@ac-#{index + 1}")
          end
          Row.new(ticket: ticket, number: index + 1, criterion: criterion, scenarios: matching)
        end
      end
    end

    def matrix_markdown(plan)
      run = plan.evidence_runs.last
      return "No test evidence recorded yet. Run `plan-driven evidence #{plan.key}`." unless run

      rows = matrix(plan).map do |row|
        scenario = row.scenarios.map { |s| "#{s["name"]} (`#{s["file"]}`)" }.join("; ").presence || "-"
        ["#{row.ticket.key}.#{row.number}", row.criterion, scenario, "#{MARKS[row.status]} #{row.status}"]
      end
      commit = run.commit_sha.present? ? " on commit `#{run.commit_sha[0, 7]}`" : ""
      intro = "Cucumber, run #{run.created_at.strftime("%-d %b %Y %H:%M")}#{commit}: `#{run.command}`"
      "#{intro}\n\n#{Renderer::Markdown.table(%w[AC Criterion Scenario Result], rows)}"
    end

    def summary_line(plan)
      return "No test evidence recorded yet." unless plan.evidence_runs.any?

      rows = matrix(plan)
      passed = rows.count { |row| row.status == "passed" }
      "#{passed} of #{rows.size} acceptance criteria are proven by a passing scenario."
    end
  end
end
