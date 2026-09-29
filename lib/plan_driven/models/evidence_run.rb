# frozen_string_literal: true

module PlanDriven
  class EvidenceRun < Record
    belongs_to :plan, class_name: "PlanDriven::Plan", inverse_of: :evidence_runs

    validates :kind, :status, presence: true

    def scenarios
      Array((results || {})["scenarios"])
    end

    def passed?
      status == "passed"
    end
  end
end
