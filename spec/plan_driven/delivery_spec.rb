# frozen_string_literal: true

RSpec.describe PlanDriven::Delivery do
  let(:github) { FakeGitHub.new }
  let(:agents) { FakeAgents.new }

  def pr_files(ticket)
    [{ "filename" => "spec/models/form_spec.rb", "status" => "modified", "additions" => 20, "deletions" => 0 },
     { "filename" => "features/#{ticket.plan.slug}/#{ticket.key.downcase}.feature", "status" => "added",
       "additions" => 10, "deletions" => 0 }]
  end

  def open_pr(ticket, number)
    github.pulls[number] = { "number" => number, "title" => "[#{ticket.reference}] #{ticket.title}",
                             "body" => "Closes ##{ticket.issue_number}", "head" => { "sha" => "sha#{number}" } }
    github.files[number] = pr_files(ticket)
    github.contents[[pr_files(ticket).last["filename"], "sha#{number}"]] = feature_for(ticket)
  end

  it "takes a plan from the interview to delivered, leaving a trail" do
    llm = FakeLLM.new(plan_reply, tickets_reply)
    flow = delivery(llm: llm, github: github, agents: agents)

    plan, result = flow.create_plan(title: "Polymorphic form ownership", answers: answers)
    expect(result.report).to be_ok
    expect(plan.status).to eq("draft")
    expect(root.join("docs/plans/#{plan.slug}/plan.md").read).to include("# #{plan.key}: Polymorphic form ownership")

    flow.submit(plan)
    expect(flow.approve_plan(plan, role: "review")).to eq([])
    expect(plan.reload.status).to eq("approved")

    flow.draft_tickets(plan)
    expect(plan.reload.status).to eq("ticketed")
    expect(plan.tickets.map(&:title).first).to eq("Migration: Add polymorphic ownership to forms")

    expect(flow.approve_tickets(plan, role: "review")).to eq([])
    expect(plan.reload.status).to eq("tickets_approved")
    expect(github.issues.map do |issue|
      issue[:title]
    end.first).to eq("[#{plan.key}/T1] Migration: Add polymorphic ownership to forms")

    # Only T1 is ready: everything else waits on it.
    expect(flow.develop(plan).map(&:key)).to eq(["T1"])
    expect(plan.reload.status).to eq("in_development")
    expect(agents.launched.first[:prompt]).to include("#{plan.key}/T1", "@#{plan.key.downcase}-t1")

    %w[T1 T2 T3 T4 T5].each_with_index do |key, index|
      flow.develop(plan)
      ticket = plan.ticket!(key)
      expect(ticket.status).to eq("running"), "#{key} should be running, is #{ticket.status}"
      agents.finish(ticket, pr: 100 + index)
      open_pr(ticket, 100 + index)
      flow.refresh(plan)
      expect(ticket.reload.status).to eq("pr_open")
      flow.approve_pr(ticket)
      flow.merge(ticket.reload)
    end

    expect(plan.reload.status).to eq("delivered")
    expect(github.merged.map { |merge| merge[:number] }).to eq([100, 101, 102, 103, 104])

    scenarios = plan.tickets.flat_map do |ticket|
      ticket.criteria.each_index.map { |i| { feature_tag: ticket.feature_tag, tags: ["@ac-#{i + 1}"] } }
    end
    PlanDriven::Evidence.record(plan, cucumber_json(scenarios), command: "cucumber", actor: flow.actor)
    report = flow.report(plan)

    markdown = report[:markdown].read
    expect(markdown).to include("7 of 7 acceptance criteria are proven by a passing scenario")
    expect(plan.events.pluck(:name)).to include("plan.drafted", "plan.approved", "tickets.approved",
                                                "ticket.agent_started", "ticket.pr_opened", "ticket.merged",
                                                "plan.delivered", "evidence.recorded", "report.written")
  end

  describe "plan approval" do
    let(:flow) { delivery }

    it "won't submit a plan that fails its guards" do
      plan = create_plan(sections: all_sections.except("why"))
      expect { flow.submit(plan) }.to raise_error(PlanDriven::GuardError) { |error| expect(error.problems).to include("Why is empty") }
      expect(plan.reload.status).to eq("draft")
    end

    it "needs every configured role" do
      PlanDriven.configuration.plan_approvals = %w[review qa devops]
      plan = create_plan(status: "in_review")
      expect(flow.approve_plan(plan, role: "qa")).to eq(%w[review devops])
      expect(plan.reload.status).to eq("in_review")
    end

    it "rejects a role the project doesn't use" do
      plan = create_plan(status: "in_review")
      expect { flow.approve_plan(plan, role: "cto") }.to raise_error(ArgumentError, /unknown role cto/)
    end

    it "can't approve a draft" do
      expect { flow.approve_plan(create_plan, role: "review") }.to raise_error(PlanDriven::TransitionError)
    end

    it "sends a rejected plan back to draft" do
      plan = create_plan(status: "in_review")
      flow.reject_plan(plan, role: "review", note: "Needs a rollback plan")
      expect(plan.reload.status).to eq("draft")
      expect(plan.approvals.last.note).to eq("Needs a rollback plan")
    end

    it "asks for approval again after an approved plan is edited" do
      plan = create_plan(status: "in_review")
      flow.approve_plan(plan, role: "review")
      flow.edit_section(plan.reload, "monitoring", "Watch the backfill job and form load errors.")
      expect(plan.reload.status).to eq("draft")
      expect(plan.revision).to eq(2)
      expect(plan.missing_approvals).to eq(["review"])
    end
  end

  describe "tickets" do
    it "refuses a breakdown that still fails after the repair attempts" do
      bad = { "tickets" => [Fixtures::TICKETS.first.merge("acceptance_criteria" => [])] }
      flow = delivery(llm: FakeLLM.new(bad, bad, bad))
      plan = create_plan(status: "approved")
      expect { flow.draft_tickets(plan) }.to raise_error(PlanDriven::GuardError)
      expect(plan.tickets).to be_empty
    end

    it "needs an approved plan" do
      expect { delivery.draft_tickets(create_plan) }.to raise_error(PlanDriven::TransitionError, /is draft/)
    end

    it "doesn't create issues when syncing is off" do
      PlanDriven.configuration.sync_issues = false
      plan = create_ticketed_plan(status: "ticketed", ticket_status: "draft")
      delivery(github: github).approve_tickets(plan, role: "review")
      expect(github.issues).to be_empty
      expect(plan.tickets.map(&:status).uniq).to eq(["approved"])
    end
  end

  describe "development" do
    let(:flow) { delivery(github: github, agents: agents) }
    let(:plan) { create_ticketed_plan }

    it "keeps to the parallel agent limit" do
      PlanDriven.configuration.max_parallel_agents = 1
      plan.tickets.each { |ticket| ticket.update!(depends_on: []) }
      expect(flow.develop(plan).size).to eq(1)
      expect(flow.develop(plan.reload)).to eq([])
    end

    it "starts only the tickets asked for" do
      plan.tickets.each { |ticket| ticket.update!(depends_on: []) }
      expect(flow.develop(plan, only: ["t3"]).map(&:key)).to eq(["T3"])
    end

    it "marks a ticket failed when its agent errors" do
      ticket = flow.develop(plan).first
      agents.runs[[ticket.agent_id, ticket.agent_run_id]] =
        PlanDriven::CursorAgents::Run.new(id: ticket.agent_run_id, agent_id: ticket.agent_id, status: "ERROR",
                                          result: "boom")
      flow.refresh(plan)
      expect(ticket.reload.status).to eq("failed")
    end

    it "sends feedback to the agent and runs it again" do
      ticket = flow.develop(plan).first
      agents.finish(ticket)
      open_pr(ticket, 100)
      flow.refresh(plan)
      flow.request_changes(ticket.reload, "Use a batch size of 500")
      expect(ticket.reload.status).to eq("running")
      expect(agents.follow_ups.last[:text]).to include("Use a batch size of 500")
    end

    it "won't approve a pull request that fails its guards" do
      ticket = flow.develop(plan).first
      agents.finish(ticket)
      open_pr(ticket, 100)
      github.files[100] = []
      flow.refresh(plan)
      expect { flow.approve_pr(ticket.reload) }.to raise_error(PlanDriven::GuardError)
      expect(ticket.reload.status).to eq("pr_open")
    end

    it "won't merge while CI is running" do
      ticket = flow.develop(plan).first
      agents.finish(ticket)
      open_pr(ticket, 100)
      flow.refresh(plan)
      flow.approve_pr(ticket.reload)
      github.check_results["sha100"] = [{ "name" => "CI", "status" => "in_progress" }]
      expect { flow.merge(ticket.reload) }.to raise_error(PlanDriven::GuardError, /CI is still running/)
    end

    it "notices a pull request merged on GitHub" do
      ticket = flow.develop(plan).first
      agents.finish(ticket)
      open_pr(ticket, 100)
      flow.refresh(plan)
      github.pulls[100] =
        github.pulls[100].merge("merged" => true, "merge_commit_sha" => "abc", "merged_by" => { "login" => "ada" })
      flow.refresh(plan)
      expect(ticket.reload.status).to eq("merged")
      expect(plan.events.last.payload).to include("outside_plan_driven" => true)
    end
  end
end
