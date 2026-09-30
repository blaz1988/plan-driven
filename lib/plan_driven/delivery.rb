# frozen_string_literal: true

module PlanDriven
  # The whole process, one method per step. Each step checks the phase, runs its guard, records
  # who did it, and leaves documentation behind. The CLI is a thin layer over this.
  class Delivery
    attr_reader :actor, :config

    def initialize(actor: PlanDriven.actor, config: PlanDriven.configuration, llm: nil, schema: nil,
                   github: nil, agents: nil)
      @actor = actor
      @config = config
      @llm = llm
      @schema = schema
      @github = github
      @agents = agents
    end

    # -- Plan -------------------------------------------------------------------------------------

    def create_plan(title:, answers:)
      result = drafter.draft(answers, title: title)
      plan = Plan.create!(title: title, interview: answers, sections: result.sections, created_by: actor,
                          guard_report: result.report.to_h)
      plan.log!("plan.drafted", actor: actor, model: llm.label, attempts: result.attempts,
                                assumptions: result.assumptions)
      Usage.record_llm(plan, llm, "plan drafted", actor: actor)
      Renderer.write_plan(plan, config: config)
      [plan, result]
    end

    def check_plan(plan)
      report = Guards::PlanGuard.new(plan.sections, schema: schema, template: config.template).call
      plan.update!(guard_report: report.to_h)
      report
    end

    def edit_section(plan, key, text)
      plan.update_sections!({ key => text }, actor: actor)
      check_plan(plan)
      Renderer.write_plan(plan, config: config)
    end

    def redraft_section(plan, key, instruction)
      text = drafter.redraft(plan.sections, key, instruction)
      edit_section(plan, key, text)
      Usage.record_llm(plan, llm, "#{key} redrafted", actor: actor)
      text
    end

    def submit(plan)
      report = check_plan(plan)
      raise GuardError, report.errors unless report.ok?

      Workflow.plan_transition!(plan, "in_review")
      plan.log!("plan.submitted", actor: actor, revision: plan.revision, warnings: report.warnings)
      Renderer.write_plan(plan, config: config)
    end

    def approve_plan(plan, role:, note: nil)
      decide(plan, role: role, decision: "approved", note: note)
      if plan.missing_approvals.empty?
        Workflow.plan_transition!(plan, "approved")
        plan.log!("plan.approved", actor: actor, revision: plan.revision)
      end
      Renderer.write_plan(plan, config: config)
      plan.missing_approvals
    end

    def reject_plan(plan, role:, note:)
      decide(plan, role: role, decision: "rejected", note: note)
      Workflow.plan_transition!(plan, "draft")
      plan.log!("plan.changes_requested", actor: actor, note: note)
      Renderer.write_plan(plan, config: config)
    end

    # -- Tickets ----------------------------------------------------------------------------------

    def draft_tickets(plan, instruction: nil)
      require_status!(plan, %w[approved ticketed])
      result = begin
        TicketGenerator.new(llm: llm, schema: schema, config: config).generate(plan, instruction: instruction)
      ensure
        Usage.record_llm(plan, llm, instruction ? "tickets redrafted" : "tickets drafted", actor: actor)
      end
      raise GuardError, result.report.errors unless result.report.ok?

      replace_tickets(plan, result)
      Renderer.write_plan(plan, config: config)
      result
    end

    def approve_tickets(plan, role:, note: nil)
      require_status!(plan, %w[ticketed])
      decide(plan, role: "tickets:#{role}", decision: "approved", note: note)
      return plan.missing_ticket_approvals if plan.missing_ticket_approvals.any?

      Plan.transaction do
        plan.tickets.each { |ticket| Workflow.ticket_transition!(ticket, "approved") }
        Workflow.plan_transition!(plan, "tickets_approved")
        plan.log!("tickets.approved", actor: actor, count: plan.tickets.size)
      end
      sync_issues(plan) if config.sync_issues
      Renderer.write_plan(plan, config: config)
      []
    end

    def sync_issues(plan)
      plan.tickets.reject(&:issue_number).each do |ticket|
        issue = github.create_issue(title: "[#{ticket.reference}] #{ticket.title}", body: issue_body(ticket),
                                    labels: config.issue_labels + [plan.key.downcase, ticket.kind])
        ticket.update!(issue_number: issue["number"])
        plan.log!("ticket.issue_created", actor: actor, ticket: ticket, issue: issue["number"])
      end
    end

    # -- Development ------------------------------------------------------------------------------

    # Ready tickets, within the parallel agent limit, optionally narrowed to the given keys.
    def startable(plan, only: nil)
      capacity = [config.max_parallel_agents - plan.tickets.count(&:active_agent?), 0].max
      candidates = plan.tickets.select(&:ready?)
      keys = Array(only).map(&:upcase)
      candidates = candidates.select { |ticket| keys.include?(ticket.key) } if keys.any?
      candidates.first(capacity)
    end

    def develop(plan, only: nil)
      require_status!(plan, %w[tickets_approved in_development])
      launched = startable(plan, only: only).map { |ticket| launch(ticket) }
      Workflow.plan_transition!(plan, "in_development") if launched.any? && plan.status == "tickets_approved"
      launched
    end

    def launch(ticket, prompt: AgentPrompt.new(ticket, config: config))
      agent, run = agents.launch(prompt: prompt.to_s, repo_url: github.repo_url, name: prompt.pr_title)
      Workflow.ticket_transition!(ticket, "running")
      ticket.update!(agent_id: agent["id"], agent_run_id: run.id, agent_url: agent["url"])
      ticket.plan.log!("ticket.agent_started", actor: actor, ticket: ticket, agent: agent["id"], run: run.id)
      ticket
    end

    # Polls running agents and open pull requests, moving tickets along as work lands.
    def refresh(plan)
      plan.tickets.each do |ticket|
        case ticket.status
        when "running" then refresh_agent(ticket)
        when "pr_open", "pr_approved" then refresh_pull(ticket)
        end
      end
      finish(plan)
      plan.tickets.reset
    end

    def review(ticket)
      require_ticket_status!(ticket, %w[pr_open pr_approved])
      pull = github.pull(ticket.pr_number)
      files = github.pull_files(ticket.pr_number)
      features = feature_files(files, pull.dig("head", "sha"))
      checks = github.checks(pull.dig("head", "sha"))
      report = Guards::PrGuard.new(ticket, pull: pull, files: files, checks: checks, features: features,
                                           behind: github.behind_by(pull), config: config).call
      ticket.update!(guard_report: report.to_h)
      ticket.plan.log!("ticket.reviewed", actor: actor, ticket: ticket, errors: report.errors.size,
                                          warnings: report.warnings.size)
      report
    end

    def approve_pr(ticket, note: nil)
      report = review(ticket)
      raise GuardError, report.errors unless report.ok?

      decide(ticket, role: "pr", decision: "approved", note: note)
      Workflow.ticket_transition!(ticket, "pr_approved") if ticket.status == "pr_open"
      ticket.plan.log!("ticket.pr_approved", actor: actor, ticket: ticket, pr: ticket.pr_number)
      github.review(ticket.pr_number, body: "Approved in plan-driven by #{actor}. #{note}".strip)
      report
    end

    def request_changes(ticket, feedback)
      require_ticket_status!(ticket, %w[pr_open pr_approved failed])
      decide(ticket, role: "pr", decision: "rejected", note: feedback) unless ticket.status == "failed"
      Workflow.ticket_transition!(ticket, "changes_requested") unless ticket.status == "failed"
      run = agents.follow_up(ticket.agent_id, follow_up_prompt(ticket, feedback))
      Workflow.ticket_transition!(ticket, "running")
      ticket.update!(agent_run_id: run.id)
      ticket.plan.log!("ticket.changes_requested", actor: actor, ticket: ticket, feedback: feedback, run: run.id)
      ticket
    end

    def merge(ticket)
      require_ticket_status!(ticket, %w[pr_approved])
      require_mergeable!(ticket)
      github.ready_for_review(ticket.pr_number) if github.pull(ticket.pr_number)["draft"]
      result = github.merge(ticket.pr_number, title: "#{ticket.title} (#{ticket.reference})",
                                              method: config.merge_method)
      ticket.update!(merged_sha: result["sha"])
      Workflow.ticket_transition!(ticket, "merged")
      clean_up_agent(ticket)
      ticket.plan.log!("ticket.merged", actor: actor, ticket: ticket, sha: result["sha"])
      finish(ticket.plan)
      ticket
    end

    # -- Evidence and report ----------------------------------------------------------------------

    def evidence(plan, command: nil)
      Evidence.run_cucumber(plan, actor: actor, command: command)
    end

    def report(plan)
      plan.log!("report.written", actor: actor)
      Renderer.write_report(plan, config: config)
    end

    private

    def require_mergeable!(ticket)
      report = review(ticket)
      raise GuardError, report.errors unless report.ok?
      return unless report.warnings.any? { |warning| warning.include?("still running") }

      raise GuardError, ["CI is still running; wait for it to finish"]
    end

    def decide(record, role:, decision:, note:)
      plan = record.is_a?(Plan) ? record : record.plan
      if record.is_a?(Plan) && !role.start_with?("tickets:")
        require_status!(plan, %w[in_review])
        allowed = config.plan_approvals.map(&:to_s)
        unless allowed.include?(role.to_s)
          raise ArgumentError,
                "unknown role #{role}; this project approves as #{allowed.join(", ")}"
        end
      end
      record.approvals.create!(role: role.to_s, decision: decision, actor: actor, note: note, revision: plan.revision)
    end

    def refresh_agent(ticket)
      run = agents.run(ticket.agent_id, ticket.agent_run_id)
      return unless run.terminal?

      Usage.record_agent(ticket, run, agents, actor: actor, config: config)
      if run.finished? && run.pr_url
        ticket.update!(pr_url: run.pr_url, pr_number: GitHub.pr_number(run.pr_url), branch: run.branch)
        Workflow.ticket_transition!(ticket, "pr_open")
        ticket.plan.log!("ticket.pr_opened", actor: agent_actor, ticket: ticket, pr: run.pr_url)
      else
        Workflow.ticket_transition!(ticket, "failed")
        ticket.plan.log!("ticket.agent_failed", actor: agent_actor, ticket: ticket, status: run.status,
                                                result: run.result.to_s[0, 500])
      end
    end

    def refresh_pull(ticket)
      pull = github.pull(ticket.pr_number)
      return unless pull["merged"]

      ticket.update!(merged_sha: pull["merge_commit_sha"])
      Workflow.ticket_transition!(ticket, "merged")
      clean_up_agent(ticket)
      ticket.plan.log!("ticket.merged", actor: pull.dig("merged_by", "login") || "github", ticket: ticket,
                                        sha: pull["merge_commit_sha"], outside_plan_driven: true)
    end

    def finish(plan)
      plan.tickets.reset
      return unless plan.status == "in_development" && plan.tickets.all? { |ticket| ticket.status == "merged" }

      Workflow.plan_transition!(plan, "delivered")
      plan.log!("plan.delivered", actor: actor)
    end

    def clean_up_agent(ticket)
      agents.cleanup(ticket.agent_id) if ticket.agent_id && agents.respond_to?(:cleanup)
    end

    def agent_actor
      "#{config.agent_provider}-agent"
    end

    def feature_files(files, sha)
      files.select { |file| file["filename"].end_with?(".feature") && file["status"] != "removed" }
           .to_h { |file| [file["filename"], github.file(file["filename"], ref: sha)] }
    end

    def follow_up_prompt(ticket, feedback)
      report = Guards::Report.from_h(ticket.guard_report)
      checks = if report.errors.any?
                 "\n\nThe automated checks also found:\n#{report.errors.map do |e|
                   "- #{e}"
                 end.join("\n")}"
               else
                 ""
               end
      "Review feedback on the pull request for #{ticket.reference}:\n\n#{feedback}#{checks}\n\n" \
        "Push the fixes to the same branch. Keep the pull request title and description format."
    end

    def issue_body(ticket)
      criteria = ticket.criteria.each_with_index.map { |criterion, index| "- [ ] #{index + 1}. #{unlinked(criterion)}" }
      notes = ticket.implementation_notes.presence
      <<~MD
        #{unlinked(ticket.story)}

        #{unlinked(ticket.description)}

        ### Acceptance criteria
        #{criteria.join("\n")}
        #{"\n### Implementation notes\n#{unlinked(notes)}\n" if notes}
        ---
        Plan #{ticket.plan.key}: #{ticket.plan.title} · kind: #{ticket.kind} · estimate: #{ticket.estimate}
        #{"· depends on #{ticket.dependencies.join(", ")}" if ticket.dependencies.any?}
      MD
    end

    # GitHub links "#1" and "@name" anywhere outside code, so "You're #1 on the waitlist" would point
    # at an unrelated pull request and "(@event)" would mention a user. An empty comment breaks
    # the link and renders nothing.
    def unlinked(text)
      text.to_s.split(/(```.*?```|`[^`\n]*`)/m).each_with_index.map do |part, index|
        index.odd? ? part : part.gsub(/(?<![\w&])([#@])(?=\w)/, '\1<!-- -->')
      end.join
    end

    def replace_tickets(plan, result)
      Plan.transaction do
        plan.tickets.destroy_all
        result.tickets.each { |attributes| plan.tickets.create!(ticket_attributes(attributes)) }
        Workflow.plan_transition!(plan, "ticketed") if plan.status == "approved"
        plan.log!("tickets.drafted", actor: actor, count: result.tickets.size, attempts: result.attempts,
                                     fixes: result.report.fixes, warnings: result.report.warnings)
      end
      plan.tickets.reset
    end

    def ticket_attributes(attributes)
      {
        key: attributes["key"], position: attributes["position"], title: attributes["title"],
        kind: attributes["kind"], ticket_type: attributes["type"], story: attributes["story"],
        description: attributes["description"], acceptance_criteria: attributes["acceptance_criteria"],
        implementation_notes: attributes["implementation_notes"], estimate: attributes["estimate"],
        depends_on: attributes["depends_on"], touches: attributes["touches"]
      }
    end

    def require_status!(plan, statuses)
      return if statuses.include?(plan.status)

      raise TransitionError, "plan #{plan.key} is #{plan.status} (#{Workflow::PLAN_DESCRIPTIONS[plan.status]})"
    end

    def require_ticket_status!(ticket, statuses)
      return if statuses.include?(ticket.status)

      raise TransitionError, "ticket #{ticket.reference} is #{ticket.status}; this needs #{statuses.join(" or ")}"
    end

    def drafter
      Drafter.new(llm: llm, schema: schema, config: config)
    end

    def llm
      @llm = MeteredLLM.new(@llm || LLM.new(config)) unless @llm.is_a?(MeteredLLM)
      @llm
    end

    def schema
      @schema ||= SchemaContext.new
    end

    def github
      @github ||= GitHub.new
    end

    def agents
      @agents ||= Agents.build(config)
    end
  end
end
