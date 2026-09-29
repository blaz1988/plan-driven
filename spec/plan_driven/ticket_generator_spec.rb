# frozen_string_literal: true

RSpec.describe PlanDriven::TicketGenerator do
  let(:plan) { create_plan(status: "approved") }

  def generate(llm)
    described_class.new(llm: llm, schema: schema).generate(plan)
  end

  it "normalizes and checks the tickets" do
    result = generate(FakeLLM.new(tickets_reply))
    expect(result.report).to be_ok
    expect(result.tickets.map { |t| t["key"] }).to eq(%w[T1 T2 T3 T4 T5])
    expect(result.report.fixes).to include(a_string_matching(/T1: title prefixed/))
  end

  it "sends the plan with section titles" do
    llm = FakeLLM.new(tickets_reply)
    generate(llm)
    expect(llm.calls.first[:messages].first[:content]).to include("Plan #{plan.key}: Polymorphic form ownership",
                                                                  "## Database changes")
    expect(llm.calls.first[:system].squish).to include("at most 5 points on the scale 1, 2, 3, 5, 8")
  end

  it "repairs a breakdown that violates expand and contract" do
    wrong = { "tickets" => Fixtures::TICKETS.map { |t| t["key"] == "T2" ? t.merge("depends_on" => []) : t } }
    llm = FakeLLM.new(wrong, tickets_reply)
    result = generate(llm)
    expect(result.attempts).to eq(2)
    expect(llm.calls.last[:messages].last[:content]).to include("T2 (dual_write) touches forms but doesn't depend on T1")
  end

  it "asks again for a reply without tickets" do
    expect(generate(FakeLLM.new({ "items" => [] }, tickets_reply)).report).to be_ok
  end
end
