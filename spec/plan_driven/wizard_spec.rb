# frozen_string_literal: true

RSpec.describe PlanDriven::Wizard do
  describe PlanDriven::Wizard::Commands do
    def argv(action, **fields)
      described_class.argv(action, fields)
    end

    it "builds each command the wizard offers, always with --yes" do
      expect(argv("new", title: " Event categories ")).to eq(["new", "Event categories", "--yes"])
      expect(argv("submit", plan: "pd-2")).to eq(%w[submit PD-2 --yes])
      expect(argv("edit", plan: "PD-2", section: "database_changes", file: "tmp/x.md"))
        .to eq(%w[edit PD-2 database_changes --from tmp/x.md --yes])
      expect(argv("redraft", plan: "PD-2", section: "testing", instruction: "add permission cases"))
        .to eq(["redraft", "PD-2", "testing", "add permission cases", "--yes"])
      expect(argv("approve", plan: "PD-2", role: "qa", note: "fine")).to eq(%w[approve PD-2 --as qa --note fine --yes])
      expect(argv("approve", plan: "PD-2", role: "", note: "")).to eq(%w[approve PD-2 --yes])
      expect(argv("tickets", plan: "PD-2", instruction: "")).to eq(%w[tickets PD-2 --yes])
      expect(argv("develop", plan: "PD-2", tickets: %w[t1 T3])).to eq(%w[develop PD-2 T1 T3 --yes])
      expect(argv("merge", plan: "PD-2", ticket: "t2")).to eq(%w[merge PD-2/T2 --yes])
      expect(argv("feedback", plan: "PD-2", ticket: "T2", feedback: "rename it"))
        .to eq(["feedback", "PD-2/T2", "rename it", "--yes"])
      expect(argv("doctor")).to eq(%w[doctor --yes])
    end

    it "refuses anything outside the list, and arguments that don't look right" do
      expect { argv("configure") }.to raise_error(ArgumentError, /can't run `configure`/)
      expect { argv("submit", plan: "PD-1; rm -rf /") }.to raise_error(ArgumentError, "not a plan key")
      expect { argv("merge", plan: "PD-1", ticket: "T1 --admin") }.to raise_error(ArgumentError, "not a ticket key")
      expect { argv("edit", plan: "PD-1", section: "nope", file: "x") }.to raise_error(ArgumentError, /unknown section/)
      expect { argv("reject", plan: "PD-1", note: " ") }.to raise_error(ArgumentError, "note is required")
      expect { argv("new", title: "") }.to raise_error(ArgumentError, "title is required")
    end
  end

  describe PlanDriven::Wizard::Job do
    before do
      FileUtils.mkdir_p(@root.join("bin"))
      File.write(@root.join("bin/plan-driven"), <<~SH)
        #!/bin/sh
        echo "args: $*"
        echo "actor: $PLAN_DRIVEN_ACTOR"
        cat
        [ "$1" = "fail" ] && exit 3
        echo "✓ done"
      SH
      FileUtils.chmod(0o755, @root.join("bin/plan-driven"))
    end

    def finished(job)
      Timeout.timeout(5) { sleep 0.02 while job.state["status"] == "running" }
      described_class.find(job.id, root: @root).to_h
    end

    it "runs the command in the background and keeps its output and exit status" do
      job = described_class.start(%w[submit PD-1 --yes], stdin: "answer\n\n", actor: "Ana <ana@example.com>")
      result = finished(job)

      expect(result["status"]).to eq("succeeded")
      expect(result["command"]).to eq("PLAN_DRIVEN_ACTOR=Ana\\ \\<ana@example.com\\> bin/plan-driven submit PD-1 --yes")
      expect(result["output"]).to eq("args: submit PD-1 --yes\nactor: Ana <ana@example.com>\nanswer\n\n✓ done\n")
    end

    it "records a failure" do
      result = finished(described_class.start(%w[fail]))
      expect(result).to include("status" => "failed", "exit" => 3)
    end

    it "only finds jobs by their id" do
      expect { described_class.find("../../etc/passwd") }.to raise_error(ArgumentError, "not a job")
      expect { described_class.find("0" * 16) }.to raise_error(ArgumentError, /no job/)
    end
  end

  describe PlanDriven::Wizard::Steps do
    it "opens a plan on the step its phase has reached, and no further" do
      plan = PlanDriven::Plan.new(status: "ticketed")
      expect(described_class.current(plan)).to eq("tickets")
      expect(described_class.reached?(plan, "approve")).to be(true)
      expect(described_class.reached?(plan, "agents")).to be(false)
    end
  end
end
