# frozen_string_literal: true

module PlanDriven
  class Ticket < Record
    KINDS = %w[migration dual_write backfill code switch cleanup docs].freeze
    TYPES = %w[TASK STORY BUG].freeze

    belongs_to :plan, class_name: "PlanDriven::Plan", inverse_of: :tickets
    has_many :approvals, as: :approvable, class_name: "PlanDriven::Approval", dependent: :destroy

    validates :key, :title, presence: true
    validates :kind, inclusion: { in: KINDS }
    validates :ticket_type, inclusion: { in: TYPES }
    validates :status, inclusion: { in: Workflow::TICKET.keys }

    def reference
      "#{plan.key}/#{key}"
    end

    def criteria
      Array(acceptance_criteria)
    end

    def dependencies
      Array(depends_on)
    end

    def tables
      Array(touches)
    end

    def dependency_tickets
      plan.tickets.select { |ticket| dependencies.include?(ticket.key) }
    end

    # Ready to hand to an agent: approved and everything it builds on is merged, so the agent
    # starts from a branch that already contains it.
    def ready?
      status == "approved" && dependency_tickets.all? { |ticket| ticket.status == "merged" }
    end

    def blocked_by
      dependency_tickets.reject { |ticket| ticket.status == "merged" }.map(&:key)
    end

    def active_agent?
      status == "running"
    end

    def feature_tag
      "@#{plan.key.downcase}-#{key.downcase}"
    end

    def pr_approved_by
      approvals.where(role: "pr", decision: "approved").order(:created_at).last&.actor
    end
  end
end
