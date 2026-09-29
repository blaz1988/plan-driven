# frozen_string_literal: true

module PlanDriven
  class Approval < Record
    DECISIONS = %w[approved rejected].freeze

    belongs_to :approvable, polymorphic: true

    validates :role, :actor, presence: true
    validates :decision, inclusion: { in: DECISIONS }
  end
end
