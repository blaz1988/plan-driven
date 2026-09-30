# frozen_string_literal: true

RSpec.describe PlanDriven::CLI do
  let(:github) { FakeGitHub.new }
  let(:agents) { FakeAgents.new }
  let(:llm) { FakeLLM.new(plan_reply, tickets_reply) }
  let(:flow) { delivery(llm: llm, github: github, agents: agents) }
  let(:output) { StringIO.new }

  def run(*argv, input: "")
    output.truncate(0)
    output.rewind
    status = described_class.new(input: StringIO.new(input), output: output, delivery: flow, boot: false).run(argv)
    [status, output.string]
  end

  def interview_input
    PlanDriven.configuration.template.asked.map { |section| "#{Fixtures::ANSWERS[section.key]}\n\n" }.join
  end

  it "prints help" do
    status, text = run("help")
    expect(status).to eq(0)
    expect(text).to include("approve-tickets PLAN", "Phases: plan draft")
  end

  it "prints the version and exits cleanly" do
    expect(run("version")).to eq([0, "#{PlanDriven::VERSION}\n"])
  end

  it "shows the tokens each step spent, and the cost when priced" do
    PlanDriven.configuration.token_prices = { "model" => { input: 3, output: 15 } }
    run("new", "Polymorphic", "form", "ownership", input: interview_input)
    status, text = run("usage", "PD-1")
    expect(status).to eq(0)
    expect(text).to include("plan drafted", "1,200", "$0.01", "1,200 tokens, $0.01")
  end

  it "cuts a table's last column to the terminal's width" do
    terminal = StringIO.new
    def terminal.tty? = true
    def terminal.winsize = [24, 40]
    ui = PlanDriven::CLI::UI.new(output: terminal)
    ui.table(%w[Key Details], [["PD-1", "a long line of details that would wrap"]])

    lines = terminal.string.gsub(/\e\[[\d;]*m/, "").lines.map(&:chomp)
    expect(lines.last).to eq("PD-1  a long line of details that wo...")
    expect(lines.map(&:length).max).to be < 40
  end

  it "cuts the widest columns to COLUMNS when the output isn't a terminal" do
    terminal = StringIO.new
    ui = PlanDriven::CLI::UI.new(output: terminal)
    rows = [["T1", "Show comments on the event page, oldest first", "code", 3, "#29"]]
    original = ENV.fetch("COLUMNS", nil)
    ENV["COLUMNS"] = "50"
    ui.table(%w[# Title Kind Pts PR], rows)

    lines = terminal.string.gsub(/\e\[[\d;]*m/, "").lines.map(&:chomp)
    expect(lines.last).to start_with("T1  Show comments on the event...  code")
    expect(lines.last).to end_with("#29")
    expect(lines.map(&:rstrip).map(&:length).max).to be < 50
  ensure
    ENV["COLUMNS"] = original
  end

  it "rejects unknown commands" do
    expect(run("deploy")).to eq([1, "✗ Unknown command `deploy`. `plan-driven help` lists them.\n"])
  end

  it "interviews, drafts and writes the plan" do
    status, text = run("new", "Polymorphic", "form", "ownership", input: interview_input)
    expect(status).to eq(0)
    expect(text).to include("What: What are we building?", "  > Team Jarvis\n", "PD-1 drafted (1 attempt)",
                            "All checks passed", "docs/plans/pd-1-polymorphic-form-ownership/plan.md")
    expect(PlanDriven::Plan.last.section("who")).to eq("Team Jarvis")
  end

  it "replaces a section from a file, as a new revision" do
    run("new", "Polymorphic form ownership", input: interview_input)
    File.write(@root.join("who.md"), "Team Jarvis and Ana from QA\n")

    status, text = run("edit", "PD-1", "who", "--from", @root.join("who.md").to_s)
    expect(status).to eq(0)
    expect(text).to include("Who updated; PD-1 is now revision 2 (draft)")
    expect(PlanDriven::Plan.last.section("who")).to eq("Team Jarvis and Ana from QA\n")
  end

  it "insists on required answers" do
    input = "\n#{interview_input}"
    _, text = run("new", "Title", input: input)
    expect(text).to include("! What is required.")
  end

  it "walks a plan through approval to development" do
    run("new", "Polymorphic form ownership", input: interview_input)

    expect(run("submit", "PD-1").last).to include("PD-1 revision 1 is in review", "Approvals needed: review")
    expect(run("approve", "pd-1", "--note", "Looks good").last).to include("Every approval is in")
    expect(run("tickets", "PD-1").last).to include("Tickets pass every check", "Migration: Add polymorphic ownership")
    expect(run("approve-tickets", "PD-1").last).to include("5 tickets approved", "T1 -> issue #11")

    _, text = run("develop", "PD-1", input: "n\n")
    expect(text).to include("T1 Migration: Add polymorphic ownership to forms", "Nothing started.")
    expect(agents.launched).to be_empty

    _, text = run("develop", "PD-1", input: "y\n")
    expect(text).to include("T1 agent started: https://cursor.com/agents/bc-1")

    expect(run("develop", "PD-1").last).to include("No ticket is ready", "T2 waits for T1 to merge")
    expect(run("status", "PD-1").last).to include("in development", "running")
  end

  it "asks for the ticket key before merging" do
    plan = create_ticketed_plan(status: "in_development")
    ticket = plan.ticket!("T1")
    ticket.update!(pr_number: 5, pr_url: "https://github.com/acme/app/pull/5", status: "pr_approved")
    ticket.approvals.create!(role: "pr", decision: "approved", actor: "Grace", revision: 1)
    github.files[5] = [{ "filename" => "spec/a_spec.rb", "status" => "added", "additions" => 1, "deletions" => 0 }]
    github.contents[["features/t1.feature", "sha5"]] = feature_for(ticket)
    github.files[5] << { "filename" => "features/t1.feature", "status" => "added", "additions" => 1, "deletions" => 0 }

    expect(run("merge", "PD-1/T1", input: "yes\n").last).to include("approved by Grace", "Not merged.")
    expect(github.merged).to be_empty

    expect(run("status", "PD-1").last).to include("Next: `plan-driven merge PD-1/T1`")
    expect(run("merge", "PD-1/T1", input: "T1\n").last).to include("PD-1/T1 merged (merge5s)", "Now ready: T2, T3")
    expect(run("status", "PD-1").last).to include("Next: `plan-driven develop PD-1`")
  end

  it "shows guard problems and exits 1" do
    create_plan(sections: all_sections.except("why"))
    status, text = run("submit", "PD-1")
    expect(status).to eq(1)
    expect(text).to include("✗ Blocked by 1 problem(s):", "  - Why is empty")
  end

  it "explains a missing plan or ticket" do
    expect(run("show", "PD-9").last).to include("No plan PD-9")
    create_plan
    expect(run("prompt", "PD-1").last).to include("Pass a ticket as PLAN/TICKET")
  end

  it "requires a note to reject" do
    create_plan(status: "in_review")
    expect(run("reject", "PD-1").last).to include("Say what needs to change with --note.")
    expect(run("reject", "PD-1", "--note", "Add rollback").last).to include("sent back to draft: Add rollback")
  end

  it "lists plans and prints one section" do
    create_plan
    expect(run("list").last).to include("PD-1  Polymorphic form ownership  draft")
    expect(run("show", "PD-1", "--section", "who").last).to eq("Team Jarvis\n")
  end

  it "records evidence from a Cucumber JSON file" do
    plan = create_ticketed_plan(status: "delivered", ticket_status: "merged")
    file = root.join("cucumber.json")
    scenarios = plan.tickets.flat_map do |ticket|
      ticket.criteria.each_index.map { |i| { feature_tag: ticket.feature_tag, tags: ["@ac-#{i + 1}"] } }
    end
    scenarios.last[:status] = "failed"
    File.write(file, cucumber_json(scenarios))

    _, text = run("evidence", "PD-1", "--from", file.to_s)
    expect(text).to include("T5.1  failed", "T1.1  passed", "6 of 7 acceptance criteria are proven")
    expect(run("report", "PD-1").last).to include("Delivery report for PD-1 written", "delivery-report.md")
  end

  it "checks the setup outside an application" do
    allow(PlanDriven::Renderer::PDF).to receive(:browser).and_return(nil)
    allow(PlanDriven::Credentials).to receive(:source).and_return(nil)
    _, text = Dir.chdir(root) { run("doctor") }
    expect(text).to include("Not in a Rails application", "LLM: openai/gpt-4.1", "! openai_api_key: not set",
                            "GitHub repository: acme/app", "PDF: no Chrome or Chromium")
    expect(text).not_to include("anthropic_api_key")
  end

  it "reads names and answers typed under a non-UTF-8 locale as text" do
    stub_const("ENV", ENV.to_h.merge("PLAN_DRIVEN_ACTOR" => (+"Ivan Blažević").force_encoding(Encoding::BINARY)))
    flow = delivery(llm: llm, actor: PlanDriven.actor)
    answers = interview_input.sub("Team Jarvis", "Tim Čačić").b
    status = described_class.new(input: StringIO.new(answers), output: output, delivery: flow, boot: false)
                            .run(%w[new Q&A])
    expect(status).to eq(0)
    plan = PlanDriven::Plan.last
    expect([plan.created_by, plan.section("who")]).to eq(["Ivan Blažević", "Tim Čačić"])
    expect(root.join("docs/plans/#{plan.slug}/plan.md").read(encoding: "UTF-8")).to include("Created by Ivan Blažević")
  end

  it "changes, adds and removes interview questions" do
    status, text = run("question", "who", "--ask", "Who owns it, and who reviews?", "--yes")
    expect(status).to eq(0)
    expect(text).to include("Question who changed", "Who owns it, and who", "changed")

    status, text = run("question", "metric", "--title", "Metric", "--ask", "Which number moves?", "--required")
    expect(status).to eq(0)
    expect(text).to include("Question metric added", "metric", "added")
    expect(PlanDriven.configuration.template["metric"].required).to be(true)

    expect(run("question", "metric", "--remove").last).to include("Question metric removed")
    expect(run("question", "who", "--remove").last).to include("Question who is back to the default")
    expect(run("question", "security", "--ask", "?")).to eq([1, "✗ security is drafted by the model, not asked; " \
                                                                "only asked questions can be changed\n"])
  end

  describe "connect" do
    let(:transport) { FakeTransport.new }

    before { PlanDriven::HTTP.transport = transport }

    it "checks a key with the service, then stores it without printing it" do
      transport.on(:get, %r{api.cursor.com/v1/me\z}, body: { userEmail: "ana@example.com" })
      status, text = run("connect", "cursor", input: "key_secret\n")

      expect(status).to eq(0)
      expect(text).to include("Cursor: connected as ana@example.com", "stored in", "never in the app")
      expect(text).not_to include("key_secret")
      expect(PlanDriven::Credentials.read["cursor_api_key"]).to eq("key_secret")
    end

    it "stores nothing when the service refuses the key" do
      transport.on(:get, %r{api.github.com/user\z}, status: 401, body: { message: "Bad credentials" })
      status, text = run("connect", "github", input: "ghp_wrong\n")

      expect(status).to eq(1)
      expect(text).to include("GitHub refused the key (HTTP 401); nothing was stored.")
      expect(PlanDriven::Credentials.read).not_to have_key("github_token")
    end

    it "needs a key" do
      expect(run("connect", "openai", input: "\n")).to include(a_string_including("No key given; nothing was stored."))
    end
  end

  it "writes the audit log" do
    plan = create_plan(status: "in_review")
    flow.approve_plan(plan, role: "review")
    expect(run("log", "PD-1").last).to include("plan.approved", "Ada <ada@example.com>")
  end
end
