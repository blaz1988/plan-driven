# frozen_string_literal: true

RSpec.describe "Models and workflow" do
  describe PlanDriven::Plan do
    it "numbers plans PD-1, PD-2, ..." do
      expect([create_plan.key, create_plan.key]).to eq(%w[PD-1 PD-2])
    end

    it "is found by key, lowercase key or id" do
      plan = create_plan
      expect(PlanDriven::Plan.find_by_reference!("pd-1")).to eq(plan)
      expect(PlanDriven::Plan.find_by_reference!(plan.id.to_s)).to eq(plan)
      expect do
        PlanDriven::Plan.find_by_reference!("PD-7")
      end.to raise_error(ActiveRecord::RecordNotFound, /No plan PD-7/)
    end

    it "has a slug for its documentation folder" do
      expect(create_plan.slug).to eq("pd-1-polymorphic-form-ownership")
    end

    it "can't change once tickets are drafted" do
      plan = create_plan(status: "ticketed")
      expect do
        plan.update_sections!({ "why" => "x" }, actor: "a")
      end.to raise_error(PlanDriven::TransitionError, /follow-up plan/)
    end

    it "keeps an append-only event log" do
      event = create_plan.log!("plan.drafted", actor: "a", attempts: 1)
      expect(event.payload).to eq("attempts" => 1)
      expect { event.update!(name: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe PlanDriven::Ticket do
    let(:plan) { create_ticketed_plan }

    it "is referenced and tagged with its plan" do
      ticket = plan.ticket!("t2")
      expect(ticket.reference).to eq("PD-1/T2")
      expect(ticket.feature_tag).to eq("@pd-1-t2")
    end

    it "is ready once approved with every dependency merged" do
      t1, t2, t3, t4 = %w[T1 T2 T3 T4].map { |key| plan.ticket!(key) }
      expect([t1, t2, t3, t4].map(&:ready?)).to eq([true, false, false, false])
      t1.update!(status: "merged")
      expect([t2.reload.ready?, t3.reload.ready?, t4.reload.ready?]).to eq([true, true, false])
      expect(t4.blocked_by).to eq(%w[T2 T3])
    end
  end

  describe PlanDriven::Workflow do
    it "allows only the defined plan transitions" do
      plan = create_plan
      expect { PlanDriven::Workflow.plan_transition!(plan, "approved") }
        .to raise_error(PlanDriven::TransitionError,
                        "plan PD-1 is draft; it can't move to approved (it can move to in_review)")
      PlanDriven::Workflow.plan_transition!(plan, "in_review")
      expect(plan.reload.status).to eq("in_review")
    end

    it "allows only the defined ticket transitions" do
      ticket = create_ticketed_plan.ticket!("T1")
      expect { PlanDriven::Workflow.ticket_transition!(ticket, "merged") }.to raise_error(PlanDriven::TransitionError)
    end

    it "describes every plan phase" do
      expect(PlanDriven::Workflow::PLAN_DESCRIPTIONS.keys).to match_array(PlanDriven::Workflow::PLAN.keys)
    end
  end
end
