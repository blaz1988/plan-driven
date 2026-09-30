# frozen_string_literal: true

RSpec.describe PlanDriven::Statistics do
  let(:plan) { create_ticketed_plan(status: "delivered", ticket_status: "merged") }
  let(:start) { Time.utc(2026, 9, 30, 13, 0, 0) }
  let(:stats) { described_class.new(plan, now: start + 3600) }

  def log(name, minute, ticket: nil)
    plan.events.create!(name: name, actor: "Ada", ticket: ticket && plan.ticket!(ticket),
                        created_at: start + (minute * 60))
  end

  # T1 gets feedback once; T2 goes through first time; the rest merged without events.
  before do
    log("plan.drafted", -30)
    log("plan.approved", -20)
    log("tickets.approved", 0)
    [["ticket.agent_started", 1], ["ticket.pr_opened", 11], ["ticket.changes_requested", 15],
     ["ticket.pr_opened", 20], ["ticket.pr_approved", 22], ["ticket.merged", 23]].each { |name, at| log(name, at, ticket: "T1") }
    [["ticket.agent_started", 23], ["ticket.pr_opened", 30], ["ticket.pr_approved", 40],
     ["ticket.merged", 41]].each { |name, at| log(name, at, ticket: "T2") }
    log("plan.delivered", 41)
  end

  def minutes(row, phase)
    row.seconds(phase) / 60
  end

  it "formats durations the way people say them" do
    expect([45, 600, (3 * 3600) + 2400, 26 * 3600, nil].map { |s| described_class.duration(s) })
      .to eq(["45s", "10 min", "3 h 40 min", "1 d 2 h", "-"])
  end

  it "splits each ticket's time into queued, agent, review, fixes and merge" do
    t1, t2 = stats.tickets.first(2)
    expect(%w[queued agent review fixes merge].map { |phase| minutes(t1, phase) }).to eq([1, 10, 6, 5, 1])
    expect(%w[queued agent review fixes merge].map { |phase| minutes(t2, phase) }).to eq([23, 7, 10, 0, 1])
    expect([t1.review_rounds, t1.first_time?, t2.first_time?]).to eq([1, false, true])
    expect(t1.cycle_time / 60).to eq(22)
  end

  it "ends an unfinished segment at delivery, not at the time it's read" do
    expect(stats.tickets.last.segments.map { |segment| [segment.phase, segment.seconds / 60] }).to eq([["queued", 41]])
  end

  it "totals the work and the agents' share of it" do
    expect(stats.totals.transform_values { |seconds| seconds / 60 }.slice(*described_class::WORK))
      .to eq("agent" => 17, "review" => 16, "fixes" => 5, "merge" => 2)
    expect(stats.agent_share).to eq(55)
  end

  it "times the phases from planning to proof" do
    expect(stats.phases.map { |label, seconds| [label, seconds && (seconds / 60)] })
      .to eq([["Planning", 10], ["Tickets", 20], ["Development", 41], ["Proof", nil]])
  end

  it "burns up criteria as tickets merge and as evidence proves them" do
    t1 = plan.ticket!("T1")
    PlanDriven::Evidence.record(plan, cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"] }]),
                                command: "cucumber", actor: "ci")
    data = stats.burnup
    sizes = plan.tickets.first(2).map { |ticket| ticket.criteria.size }
    expect(data[:merged].map(&:value)).to eq([0, sizes[0], sizes.sum])
    expect(data[:proven].map(&:value)).to eq([0, 1])
    expect(data[:scope]).to eq(plan.tickets.sum { |ticket| ticket.criteria.size })
  end

  it "has nothing to chart before the tickets are approved" do
    fresh = create_plan
    expect(described_class.new(fresh).started?).to be(false)
    expect(PlanDriven::Charts.report(fresh).keys).to eq([])
  end

  describe "charts and the delivery report" do
    before do
      t1 = plan.ticket!("T1")
      json = cucumber_json([{ feature_tag: t1.feature_tag, tags: ["@ac-1"] },
                            { feature_tag: t1.feature_tag, tags: ["@ac-2"], status: "failed" }])
      PlanDriven::Evidence.record(plan, json, command: "cucumber", actor: "ci")
    end

    it "draws every chart as standalone SVG" do
      charts = PlanDriven::Charts.report(plan, stats: stats)
      expect(charts.keys).to eq(%w[statistics-proof.svg statistics-burnup.svg statistics-timeline.svg
                                   statistics-time.svg])
      expect(charts.values).to all(start_with('<svg xmlns="http://www.w3.org/2000/svg"'))
      expect(charts["statistics-timeline.svg"]).to include("Where the time went", "T1", "Agent fixing feedback")
      expect(charts["statistics-time.svg"]).to include(">55%<")
      expect(charts["statistics-proof.svg"]).to include("1 of 7 acceptance criteria proven", "1 failed")
    end

    it "writes the charts beside the report and inlines them in the HTML, with coloured results" do
      paths = PlanDriven::Renderer.write_report(plan)
      dir = paths[:markdown].dirname
      markdown = paths[:markdown].read
      html = paths[:html].read

      expect(dir.children.map { |file| file.basename.to_s }.grep(/statistics-/).sort)
        .to eq(%w[statistics-burnup.svg statistics-proof.svg statistics-time.svg statistics-timeline.svg])
      expect(markdown).to include("## Statistics", "![Where the time went, ticket by ticket](statistics-timeline.svg)",
                                  "| T1.1 |", "✅ passed", "❌ failed", "⚠️ no scenario", "| Review rounds")
      expect(html).to include('<figure class="chart"><svg', '<tr class="failed">',
                              '<span class="result passed">passed</span>')
      expect(html).not_to include("<img")
    end
  end

  it "prints the statistics in the terminal" do
    output = StringIO.new
    PlanDriven::CLI.new(input: StringIO.new, output: output, delivery: delivery, boot: false).run(%w[stats PD-1])
    expect(output.string).to include("PD-1 Polymorphic form ownership: statistics", "Planning", "10 min",
                                     "agents 55%", "Agent fixing feedback", "T1")
  end
end
