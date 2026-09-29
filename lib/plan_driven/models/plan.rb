# frozen_string_literal: true

module PlanDriven
  class Plan < Record
    has_many :tickets, -> { order(:position) }, class_name: "PlanDriven::Ticket", dependent: :destroy,
                                                inverse_of: :plan
    has_many :approvals, as: :approvable, class_name: "PlanDriven::Approval", dependent: :destroy
    has_many :events, -> { order(:created_at, :id) }, class_name: "PlanDriven::Event", dependent: :destroy,
                                                      inverse_of: :plan
    has_many :evidence_runs, -> { order(:created_at) }, class_name: "PlanDriven::EvidenceRun",
                                                        dependent: :destroy, inverse_of: :plan

    validates :key, :title, presence: true
    validates :key, uniqueness: true
    validates :status, inclusion: { in: Workflow::PLAN.keys }

    before_validation :assign_key, on: :create

    def self.find_by_reference!(reference)
      reference = reference.to_s
      find_by(key: reference.upcase) || find_by(id: reference[/\A\d+\z/]) ||
        raise(ActiveRecord::RecordNotFound, "No plan #{reference}. `plan-driven list` shows them all.")
    end

    def section(key)
      (sections || {})[key.to_s].to_s
    end

    EDITABLE = %w[draft in_review approved].freeze

    def editable?
      EDITABLE.include?(status)
    end

    # Any edit is a new revision, and approvals belong to a revision, so changing an approved
    # plan sends it back for approval.
    def update_sections!(changes, actor:)
      unless editable?
        raise TransitionError, "plan #{key} is #{status}; its tickets are drafted, so the plan can't change. " \
                               "Start a follow-up plan instead."
      end

      merged = (sections || {}).merge(changes.transform_keys(&:to_s))
      transaction do
        update!(sections: merged, revision: revision + 1)
        log!("plan.revised", actor: actor, sections: changes.keys.map(&:to_s))
        Workflow.plan_transition!(self, "draft") unless status == "draft"
      end
    end

    def slug
      "#{key.downcase}-#{title.parameterize[0, 60]}".delete_suffix("-")
    end

    def approvals_for_revision
      approvals.where(revision: revision)
    end

    def approved_roles
      approvals_for_revision.where(decision: "approved").pluck(:role).uniq
    end

    def missing_approvals(required = PlanDriven.configuration.plan_approvals)
      required.map(&:to_s) - approved_roles
    end

    def ticket_approved_roles
      approvals.where(role: ticket_roles.map { |role| "tickets:#{role}" }, decision: "approved",
                      revision: revision).pluck(:role).map { |role| role.delete_prefix("tickets:") }.uniq
    end

    def missing_ticket_approvals
      ticket_roles - ticket_approved_roles
    end

    def log!(name, actor:, ticket: nil, **payload)
      events.create!(name: name, actor: actor, ticket: ticket, payload: payload.presence)
    end

    def ticket!(reference)
      tickets.find_by(key: reference.to_s.upcase) ||
        raise(ActiveRecord::RecordNotFound, "Plan #{key} has no ticket #{reference}.")
    end

    private

    def ticket_roles
      PlanDriven.configuration.ticket_approvals.map(&:to_s)
    end

    def assign_key
      return if key.present?

      last = self.class.where("key LIKE 'PD-%'").pluck(:key).map { |value| value.delete_prefix("PD-").to_i }.max
      self.key = "PD-#{last.to_i + 1}"
    end
  end
end
