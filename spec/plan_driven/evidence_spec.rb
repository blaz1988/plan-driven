# frozen_string_literal: true

RSpec.describe PlanDriven::Evidence do
  let(:plan) { create_ticketed_plan(status: "delivered", ticket_status: "merged") }
  let(:t1) { plan.ticket!("T1") }

  it "builds a tag expression for the plan's tickets" do
    expect(described_class.tag_expression(plan)).to eq((1..5).map { |n| "@#{plan.key.downcase}-t#{n}" }.join(" or "))
  end

  describe ".parse" do
    it "reads scenarios with feature tags inherited" do
      json = cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"], name: "adds columns" }])
      expect(described_class.parse(json)).to eq([{ "name" => "adds columns", "tags" => [t1.feature_tag, "@ac-1"],
                                                   "file" => "features/#{t1.feature_tag.delete("@")}.feature:3",
                                                   "status" => "passed" }])
    end

    it "treats a scenario with a failed hook as failed and undefined steps as not run" do
      json = JSON.generate([{ "uri" => "a.feature", "elements" => [
                             { "type" => "scenario", "name" => "hook", "before" => [{ "result" => { "status" => "failed" } }],
                               "steps" => [{ "result" => { "status" => "passed" } }] },
                             { "type" => "scenario", "name" => "undefined",
                               "steps" => [{ "result" => { "status" => "undefined" } }] },
                             { "type" => "background", "name" => "bg", "steps" => [] }
                           ] }])
      expect(described_class.parse(json).map { |s| s["status"] }).to eq(["failed", "not run"])
    end

    it "returns nothing for empty or broken output" do
      expect(described_class.parse("")).to eq([])
      expect(described_class.parse("{oops")).to eq([])
    end
  end

  it "maps each acceptance criterion to its scenarios" do
    json = cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"] },
                          { feature_tag: t1.feature_tag, tags: ["@ac-2"], status: "failed" }])
    described_class.record(plan, json, command: "cucumber", actor: "ci")
    rows = described_class.matrix(plan)

    expect(rows.size).to eq(7)
    expect(rows.first(2).map(&:status)).to eq(%w[passed failed])
    expect(rows.drop(2).map(&:status).uniq).to eq(["no scenario"])
    expect(described_class.summary_line(plan)).to eq("1 of 7 acceptance criteria are proven by a passing scenario.")
    expect(described_class.matrix_markdown(plan)).to include("| T1.1 | Forms table has nullable formable_type")
  end

  it "names the commit the scenarios ran against, when there is one" do
    allow(PlanDriven::Repository).to receive(:head_sha).and_return(nil, "abcdef1234")
    described_class.record(plan, "[]", command: "cucumber", actor: "ci")
    expect(described_class.matrix_markdown(plan)).to match(/run .+: `cucumber`/).and(not_include("on commit"))
    described_class.record(plan, "[]", command: "cucumber", actor: "ci")
    expect(described_class.matrix_markdown(plan)).to include("on commit `abcdef1`: `cucumber`")
  end

  it "records a failed run when cucumber exits with an error" do
    json = cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"] }])
    expect(described_class.record(plan, json, command: "c", actor: "ci", exit_ok: false).status).to eq("failed")
    expect(described_class.record(plan, "[]", command: "c", actor: "ci").status).to eq("no scenarios")
  end

  it "runs the plan's scenarios through the given command" do
    script = root.join("fake_cucumber")
    File.write(script, "#!/bin/sh\necho \"env=$RAILS_ENV\"\n" \
                       "echo '#{cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"] }])}'\n")
    File.chmod(0o755, script)
    run = described_class.run_cucumber(plan, actor: "ci", command: [script.to_s], root: root)
    expect(run.command).to eq(script.to_s)
    expect(run.results["output"]).to include("@ac-1", "env=test")
  end

  it "says when no evidence exists yet" do
    expect(described_class.summary_line(plan)).to eq("No test evidence recorded yet.")
    expect(described_class.matrix_markdown(plan)).to include("plan-driven evidence #{plan.key}")
  end
end
