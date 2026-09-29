# frozen_string_literal: true

module PlanDriven
  module Renderer
    # The plan and the delivery report as Markdown, laid out like a Confluence implementation plan.
    module Markdown
      module_function

      def plan(plan, config: PlanDriven.configuration)
        parts = ["# #{plan.key}: #{plan.title}", meta(plan)]
        config.template.grouped.each do |group, sections|
          body = sections.filter_map { |section| section_block(plan, section, group) }
          body << tickets_table(plan) if group == "Work overview" && plan.tickets.any?
          parts << "# #{group}\n\n#{body.join("\n\n")}" if body.any?
        end
        parts << approvals_table(plan, config)
        "#{parts.join("\n\n")}\n"
      end

      def report(plan)
        parts = ["# #{plan.key}: #{plan.title} (delivery report)", meta(plan)]
        parts << "## Summary\n\n#{summary(plan)}"
        parts << "## Tickets and pull requests\n\n#{delivery_table(plan)}"
        parts << "## Acceptance criteria and proof\n\n#{Evidence.matrix_markdown(plan)}"
        parts << "## Checks run on each pull request\n\n#{guard_findings(plan)}"
        parts << "## Approvals\n\n#{approval_history(plan)}"
        parts << "## Timeline\n\n#{timeline(plan)}"
        parts << "## The approved plan\n\nThe plan this delivery implements is in `plan.md`, revision #{plan.revision}."
        "#{parts.join("\n\n")}\n"
      end

      def section_block(plan, section, group)
        text = plan.section(section.key).strip
        return if text.empty?

        heading = section.title == group ? "" : "## #{section.title}\n\n"
        "#{heading}#{text}"
      end

      def meta(plan)
        "*Status: #{plan.status.tr("_", " ")} · Revision #{plan.revision} · Created by #{plan.created_by} · " \
          "#{plan.created_at&.strftime("%-d %B %Y")}*"
      end

      def tickets_table(plan)
        rows = plan.tickets.map do |ticket|
          [ticket.key, ticket.title, ticket.ticket_type, ticket.kind, ticket.estimate,
           ticket.dependencies.join(", ").presence || "-", issue_link(ticket)]
        end
        details = plan.tickets.map { |ticket| ticket_detail(ticket) }
        "## Work items\n\n#{table(%w[# Title Type Kind Estimate Depends Issue], rows)}\n\n" \
          "**Estimated total: #{plan.tickets.sum { |ticket| ticket.estimate.to_i }} points**\n\n#{details.join("\n\n")}"
      end

      def ticket_detail(ticket)
        lines = ["### #{ticket.key}. #{ticket.title}"]
        lines << ticket.story if ticket.story.present?
        lines << ticket.description.to_s
        lines << "#### Acceptance Criteria\n\n#{ticket.criteria.each_with_index.map do |c, i|
          "#{i + 1}. #{c}"
        end.join("\n")}"
        lines << "#### Implementation Notes\n\n#{ticket.implementation_notes}" if ticket.implementation_notes.present?
        lines << "*Touches: #{ticket.tables.join(", ")}*" if ticket.tables.any?
        lines.join("\n\n")
      end

      def approvals_table(plan, config)
        roles = config.plan_approvals
        rows = roles.map do |role|
          approval = plan.approvals_for_revision.where(role: role).order(:created_at).last
          [role.tr("_", " ").capitalize, approval&.decision || "pending", approval&.actor || "",
           approval&.created_at&.strftime("%-d %b %Y %H:%M") || ""]
        end
        "# Sign-off\n\n#{table(%w[Role Decision By When], rows)}"
      end

      def summary(plan)
        tickets = plan.tickets
        merged = tickets.count { |ticket| ticket.status == "merged" }
        "#{merged} of #{tickets.size} tickets merged. #{Evidence.summary_line(plan)}"
      end

      def delivery_table(plan)
        rows = plan.tickets.map do |ticket|
          [ticket.key, ticket.title, ticket.status.tr("_", " "), pr_link(ticket),
           ticket.merged_sha.to_s[0, 7].presence || "-", ticket.pr_approved_by || "-"]
        end
        table(["#", "Ticket", "Status", "Pull request", "Merge commit", "Approved by"], rows)
      end

      def guard_findings(plan)
        lines = plan.tickets.map do |ticket|
          report = Guards::Report.from_h(ticket.guard_report)
          if ticket.guard_report.nil?
            "- **#{ticket.key}**: not reviewed"
          elsif report.errors.empty? && report.warnings.empty?
            "- **#{ticket.key}**: all checks passed"
          else
            items = report.errors.map { |e| "error: #{e}" } + report.warnings.map { |w| "warning: #{w}" }
            "- **#{ticket.key}**: #{items.join("; ")}"
          end
        end
        lines.join("\n")
      end

      def approval_history(plan)
        approvals = Approval.where(approvable: [plan, *plan.tickets]).order(:created_at)
        return "No approvals recorded." if approvals.empty?

        rows = approvals.map do |approval|
          approvable = approval.approvable
          subject = approvable.is_a?(Ticket) ? "#{approvable.key} pull request" : "plan r#{approval.revision}"
          [approval.created_at.strftime("%-d %b %Y %H:%M"), subject, approval.role, approval.decision, approval.actor,
           approval.note.to_s]
        end
        table(%w[When Subject Role Decision By Note], rows)
      end

      def timeline(plan)
        plan.events.map do |event|
          target = event.ticket ? " #{event.ticket.key}" : ""
          "- #{event.created_at.strftime("%-d %b %Y %H:%M")} · #{event.name}#{target} · #{event.actor}"
        end.join("\n")
      end

      def issue_link(ticket)
        return "-" unless ticket.issue_number

        slug = Repository.slug
        number = ticket.issue_number
        slug ? "[##{number}](https://github.com/#{slug}/issues/#{number})" : "##{number}"
      end

      def pr_link(ticket)
        ticket.pr_url ? "[##{ticket.pr_number}](#{ticket.pr_url})" : "-"
      end

      def table(headers, rows)
        escape = ->(value) { value.to_s.gsub("|", "\\|").gsub("\n", " ") }
        lines = ["| #{headers.join(" | ")} |", "| #{headers.map { "---" }.join(" | ")} |"]
        (lines + rows.map { |row| "| #{row.map(&escape).join(" | ")} |" }).join("\n")
      end
    end
  end
end
