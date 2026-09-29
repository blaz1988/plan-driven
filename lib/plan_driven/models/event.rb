# frozen_string_literal: true

module PlanDriven
  # An append-only audit trail: who did what to which plan or ticket, and when.
  class Event < Record
    belongs_to :plan, class_name: "PlanDriven::Plan", inverse_of: :events
    belongs_to :ticket, class_name: "PlanDriven::Ticket", optional: true

    validates :name, :actor, presence: true

    before_update { raise ActiveRecord::ReadOnlyRecord, "events are append-only" }
  end
end
