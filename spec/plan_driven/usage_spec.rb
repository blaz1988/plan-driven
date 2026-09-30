# frozen_string_literal: true

RSpec.describe PlanDriven::Usage do
  let(:github) { FakeGitHub.new }
  let(:agents) { FakeAgents.new }

  it "prices tokens per million, including cache" do
    PlanDriven.configuration.token_prices = { "m" => { input: 3, output: 15, cache_write: 3.75, cache_read: 0.3 } }
    tokens = { "input_tokens" => 1_000_000, "output_tokens" => 100_000, "cache_write_tokens" => 0,
               "cache_read_tokens" => 2_000_000 }
    expect(described_class.cost("m", tokens)).to eq(3 + 1.5 + 0.6)
    expect(described_class.cost("unknown", tokens)).to be_nil
  end

  it "formats token counts" do
    expect(described_class.format_tokens(12_345)).to eq("12,345")
    expect(described_class.format_tokens(2_500_000)).to eq("2.50M")
  end

  it "counts what a step spent and starts again" do
    metered = PlanDriven::MeteredLLM.new(FakeLLM.new("{}", "{}"))
    2.times { metered.chat(system: "s", messages: []) }
    expect(metered.take).to eq("calls" => 2, "input_tokens" => 2000, "output_tokens" => 400)
    expect(metered.take["calls"]).to eq(0)
    expect(metered.model).to eq("model")
  end

  it "records every model call and agent run, and reports the cost" do
    PlanDriven.configuration.token_prices = { "model" => { input: 3, output: 15 } }
    llm = FakeLLM.new(plan_reply, { "sections" => { "testing" => "Specs for every change. " * 10 } },
                      tickets_reply)
    flow = delivery(llm: llm, github: github, agents: agents)
    plan, = flow.create_plan(title: "Polymorphic form ownership", answers: answers)
    flow.redraft_section(plan, "testing", "more cases")
    flow.submit(plan)
    flow.approve_plan(plan, role: "review")
    flow.draft_tickets(plan)
    flow.approve_tickets(plan, role: "review")
    flow.develop(plan)
    ticket = plan.ticket!("T1")
    agents.finish(ticket)
    flow.refresh(plan)

    rows = described_class.rows(plan)
    expect(rows.map(&:step)).to eq(["plan drafted", "testing redrafted", "tickets drafted", "agent run"])
    expect(rows.first.tokens["input_tokens"]).to eq(1000)
    expect(rows.first.cost).to eq(0.006)
    expect(rows.last).to have_attributes(ticket: "T1", duration_ms: 540_000, model: "cursor default", cost: nil)
    expect(rows.last.total_tokens).to eq(742_040)

    markdown = PlanDriven::Renderer::Markdown.report(plan)
    expect(markdown).to include("## Tokens and cost", "| agent run | T1 | cursor default |", "9.0 min",
                                "No price is set for cursor default")
    expect(markdown).not_to include("llm.usage")
  end

  it "keeps a ticket moving when the provider can't report usage" do
    allow(agents).to receive(:usage).and_raise(PlanDriven::ProviderError, "usage unavailable")
    plan = create_ticketed_plan
    flow = delivery(github: github, agents: agents)
    flow.develop(plan)
    ticket = plan.ticket!("T1")
    agents.finish(ticket)
    flow.refresh(plan)
    expect(ticket.reload.status).to eq("pr_open")
    expect(plan.events.find_by(name: "agent.usage").payload["error"]).to eq("usage unavailable")
  end
end
