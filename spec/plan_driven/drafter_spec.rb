# frozen_string_literal: true

RSpec.describe PlanDriven::Drafter do
  def drafter(llm)
    described_class.new(llm: llm, schema: schema)
  end

  it "drafts the sections the template leaves to the model, keeping the team's answers" do
    result = drafter(FakeLLM.new(plan_reply)).draft(answers, title: "Polymorphic form ownership")
    expect(result.report).to be_ok
    expect(result.attempts).to eq(1)
    expect(result.sections["what"]).to eq(Fixtures::ANSWERS["what"])
    expect(result.sections["architecture"]).to eq(Fixtures::DRAFTED["architecture"])
    expect(result.assumptions).to eq(["Business Process remains the default owner"])
  end

  it "sends the answers and the real schema" do
    llm = FakeLLM.new(plan_reply)
    drafter(llm).draft(answers, title: "Polymorphic form ownership")
    request = llm.calls.first[:messages].first[:content]
    expect(request).to include("Plan title: Polymorphic form ownership", "Team Jarvis", "forms", "business_process_id")
    expect(llm.calls.first[:system]).to include("- security (Security):", "expand, dual write")
  end

  it "doesn't let the model overwrite the team's answers" do
    reply = plan_reply(Fixtures::DRAFTED.merge("why" => "Because the model said so."))
    result = drafter(FakeLLM.new(reply)).draft(answers, title: "x")
    expect(result.sections["why"]).to eq(Fixtures::ANSWERS["why"])
  end

  it "sends guard errors back and uses the repaired draft" do
    broken = Fixtures::DRAFTED.merge("security" => "Nothing changes for access control in any role here.")
    llm = FakeLLM.new(plan_reply(broken), plan_reply)
    result = drafter(llm).draft(answers, title: "x")
    expect(result.attempts).to eq(2)
    expect(result.report).to be_ok
    expect(llm.calls.last[:messages].last[:content]).to include("- Security doesn't state a risk level")
  end

  it "stops after the repair attempts and returns the last report" do
    broken = plan_reply(Fixtures::DRAFTED.merge("security" => "No risk level anywhere in this text at all."))
    result = drafter(FakeLLM.new(broken, broken, broken)).draft(answers, title: "x")
    expect(result.attempts).to eq(3)
    expect(result.report).not_to be_ok
  end

  it "asks again when the reply isn't usable JSON" do
    llm = FakeLLM.new("Sure! Here is your plan.", plan_reply)
    expect(drafter(llm).draft(answers, title: "x").report).to be_ok
    expect(llm.calls.last[:messages].last[:content]).to include("can't be used")
  end

  it "gives up on replies that are never JSON" do
    llm = FakeLLM.new("no", "still no", "never")
    expect { drafter(llm).draft(answers, title: "x") }.to raise_error(PlanDriven::InvalidResponseError)
  end

  it "turns lists and nested sections into Markdown" do
    reply = plan_reply(Fixtures::DRAFTED.merge("testing" => ["Model specs", "Backfill spec"],
                                               "application_changes" => { "Form" => "Dual write",
                                                                          "Project" => ["Snapshot"] }))
    sections = drafter(FakeLLM.new(reply, reply, reply)).draft(answers, title: "x").sections
    expect(sections["testing"]).to eq("- Model specs\n- Backfill spec")
    expect(sections["application_changes"]).to eq("### Form\nDual write\n\n### Project\n- Snapshot")
  end

  it "redrafts one section with the reviewer's instruction" do
    llm = FakeLLM.new({ "sections" => { "monitoring" => "Alert on backfill failures." } })
    text = drafter(llm).redraft(all_sections, "monitoring", "add alerting")
    expect(text).to eq("Alert on backfill failures.")
    expect(llm.calls.first[:messages].first[:content]).to include("Reviewer's instruction: add alerting")
  end

  it "refuses to redraft an unknown section" do
    expect { drafter(FakeLLM.new).redraft(all_sections, "nope", "x") }.to raise_error(ArgumentError, /unknown section/)
  end
end
