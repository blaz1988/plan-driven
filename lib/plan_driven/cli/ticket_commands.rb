# frozen_string_literal: true

module PlanDriven
  class CLI
    # Tickets, agents, pull requests, evidence and the report.
    module TicketCommands
      def cmd_tickets(reference = nil, *instruction)
        plan = find_plan(reference)
        ui.say "Drafting tickets for #{plan.key} with #{LLM.new.label}..."
        result = delivery.draft_tickets(plan, instruction: instruction.join(" ").presence)
        ui.report(result.report, ok_message: "Tickets pass every check")
        show_tickets(plan.tickets)
        ui.say "Next: review them in docs/plans/#{plan.slug}/plan.pdf, then `plan-driven approve-tickets #{plan.key}`."
      end

      def cmd_approve_tickets(reference = nil)
        plan = find_plan(reference)
        role = @options[:role] || PlanDriven.configuration.ticket_approvals.first
        missing = delivery.approve_tickets(plan, role: role, note: @options[:note])
        return ui.say("Approved as #{role}. Still needed: #{missing.join(", ")}") if missing.any?

        ui.success "#{plan.tickets.size} tickets approved"
        plan.tickets.select(&:issue_number).each do |ticket|
          ui.muted "  #{ticket.key} -> issue ##{ticket.issue_number}"
        end
        ui.say "Next: `plan-driven develop #{plan.key}` hands the ready tickets to Cursor agents."
      end

      def cmd_prompt(reference = nil)
        ui.say AgentPrompt.new(find_ticket(reference)).to_s
      end

      def cmd_develop(reference = nil, *only)
        plan = find_plan(reference)
        starting = delivery.startable(plan, only: only)
        return explain_waiting(plan) if starting.empty?

        starting.each { |ticket| ui.say "  #{ticket.key} #{ticket.title}" }
        return ui.muted("Nothing started.") unless ui.confirm?("Start #{starting.size} Cursor cloud agent(s)?")

        delivery.develop(plan, only: starting.map(&:key)).each do |ticket|
          ui.success "#{ticket.key} agent started: #{ticket.agent_url}"
        end
        ui.say "Each agent opens a pull request when it finishes. `plan-driven status #{plan.key}` checks on them."
      end

      def cmd_status(reference = nil)
        plan = find_plan(reference)
        delivery.refresh(plan)
        ui.heading "#{plan.key} #{plan.title}: #{plan.status.tr("_", " ")}"
        show_tickets(plan.tickets)
        ui.muted(plan.status == "in_development" ? development_hint(plan) : Workflow::PLAN_DESCRIPTIONS[plan.status])
      end

      def development_hint(plan)
        tickets = plan.tickets.to_a
        waiting = tickets.find { |t| t.status == "pr_open" }
        return "Next: `plan-driven review #{waiting.reference}`" if waiting

        approved = tickets.find { |t| t.status == "pr_approved" }
        return "Next: `plan-driven merge #{approved.reference}`" if approved
        return "Next: `plan-driven develop #{plan.key}`" if delivery.startable(plan).any?

        Workflow::PLAN_DESCRIPTIONS[plan.status]
      end

      def cmd_review(reference = nil)
        ticket = find_ticket(reference)
        ui.say "Reviewing #{ticket.pr_url}"
        report = delivery.review(ticket)
        report.passes.each { |message| ui.say "  ✓ #{message}" }
        ui.report(report, ok_message: "The pull request passes every check")
      end

      def cmd_approve_pr(reference = nil)
        ticket = find_ticket(reference)
        report = delivery.approve_pr(ticket, note: @options[:note])
        ui.report(report)
        ui.success "#{ticket.reference} pull request approved by #{delivery.actor}"
        ui.say "Next: `plan-driven merge #{ticket.reference}`"
      end

      def cmd_feedback(reference = nil, *words)
        ticket = find_ticket(reference)
        feedback = words.join(" ").presence || ui.ask_multiline("Feedback for the agent:")
        raise ArgumentError, "No feedback given." if feedback.strip.empty?

        delivery.request_changes(ticket, feedback)
        ui.success "Sent to #{ticket.reference}'s agent; it will push to the same pull request"
      end

      def cmd_merge(reference = nil)
        ticket = find_ticket(reference)
        ui.say "#{ticket.reference} #{ticket.title}"
        ui.say "#{ticket.pr_url}, approved by #{ticket.pr_approved_by}"
        return ui.muted("Not merged.") unless ui.confirm_word?(
          "This merges into #{PlanDriven.configuration.base_branch}.", ticket.key
        )

        delivery.merge(ticket)
        ui.success "#{ticket.reference} merged (#{ticket.merged_sha.to_s[0, 7]})"
        waiting = ticket.plan.tickets.select(&:ready?)
        ui.say "Now ready: #{waiting.map(&:key).join(", ")}. `plan-driven develop #{ticket.plan.key}`" if waiting.any?
        return unless ticket.plan.status == "delivered"

        ui.success "Every ticket is merged. `plan-driven report #{ticket.plan.key}`"
      end

      def cmd_evidence(reference = nil)
        plan = find_plan(reference)
        run = if @options[:from]
                Evidence.record(plan, File.read(@options[:from]), command: "imported #{@options[:from]}",
                                                                  actor: delivery.actor)
              else
                ui.say "Running cucumber --tags \"#{Evidence.tag_expression(plan)}\""
                delivery.evidence(plan)
              end
        rows = Evidence.matrix(plan)
        ui.table(%w[AC Result Criterion], rows.map do |row|
          ["#{row.ticket.key}.#{row.number}", row.status, row.criterion.truncate(70)]
        end)
        ui.say
        run.passed? ? ui.success(Evidence.summary_line(plan)) : ui.warn("#{run.status}: #{Evidence.summary_line(plan)}")
      end

      def cmd_report(reference = nil)
        plan = find_plan(reference)
        paths = delivery.report(plan)
        ui.success "Delivery report for #{plan.key} written"
        show_paths(paths.values)
      end

      private

      def explain_waiting(plan)
        running = plan.tickets.count(&:active_agent?)
        if plan.tickets.any?(&:ready?) && running >= PlanDriven.configuration.max_parallel_agents
          return ui.say("#{running} agents are already running (the limit).")
        end

        plan.tickets.select { |ticket| ticket.status == "approved" }.each do |ticket|
          ui.muted "  #{ticket.key} waits for #{ticket.blocked_by.join(", ")} to merge"
        end
        ui.say("No ticket is ready to start.")
      end

      def show_tickets(tickets)
        ui.table(%w[# Title Kind Pts Status PR], tickets.map do |ticket|
          [ticket.key, ticket.title.truncate(48), ticket.kind, ticket.estimate, ticket.status.tr("_", " "),
           ticket.pr_url.to_s]
        end)
      end
    end
  end
end
