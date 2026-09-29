# frozen_string_literal: true

module PlanDriven
  # The phases a plan and its tickets move through. Transitions are data, so the CLI, the specs
  # and the documentation all read the same table.
  module Workflow
    PLAN = {
      "draft" => %w[in_review],
      "in_review" => %w[draft approved],
      "approved" => %w[draft ticketed],
      "ticketed" => %w[approved tickets_approved],
      "tickets_approved" => %w[in_development ticketed],
      "in_development" => %w[delivered],
      "delivered" => []
    }.freeze

    TICKET = {
      "draft" => %w[approved],
      "approved" => %w[running],
      "running" => %w[pr_open failed],
      "pr_open" => %w[changes_requested pr_approved merged],
      "changes_requested" => %w[running],
      "pr_approved" => %w[merged changes_requested],
      "failed" => %w[running],
      "merged" => []
    }.freeze

    PLAN_DESCRIPTIONS = {
      "draft" => "being written; edit it, then `plan-driven submit`",
      "in_review" => "waiting for approval: `plan-driven approve`",
      "approved" => "approved; `plan-driven tickets` drafts the tickets",
      "ticketed" => "tickets drafted; review them, then `plan-driven approve-tickets`",
      "tickets_approved" => "ready; `plan-driven develop` hands tickets to agents",
      "in_development" => "agents are working; `plan-driven status` and `plan-driven review`",
      "delivered" => "every ticket merged; `plan-driven report` writes the delivery report"
    }.freeze

    module_function

    def plan_transition!(plan, to)
      transition!(PLAN, plan, to, "plan #{plan.key}")
    end

    def ticket_transition!(ticket, to)
      transition!(TICKET, ticket, to, "ticket #{ticket.key}")
    end

    def transition!(table, record, to, label)
      from = record.status
      unless table.fetch(from, []).include?(to)
        allowed = table.fetch(from, [])
        hint = allowed.empty? ? "it's final" : "it can move to #{allowed.join(", ")}"
        raise TransitionError, "#{label} is #{from}; it can't move to #{to} (#{hint})"
      end

      record.update!(status: to)
    end
  end
end
