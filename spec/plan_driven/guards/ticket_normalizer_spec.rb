# frozen_string_literal: true

RSpec.describe PlanDriven::Guards::TicketNormalizer do
  def normalize(tickets)
    report = PlanDriven::Guards::Report.new
    [described_class.new(tickets).call(report), report]
  end

  let(:base) { { "title" => "Do it", "kind" => "code", "type" => "task", "estimate" => 3 } }

  it "renumbers keys in order and remaps dependencies" do
    tickets, = normalize([base.merge("key" => "A"), base.merge("key" => "B", "depends_on" => ["A"])])
    expect(tickets.map { |t| t["key"] }).to eq(%w[T1 T2])
    expect(tickets.last["depends_on"]).to eq(["T1"])
  end

  it "upcases the type and defaults it to TASK" do
    tickets, = normalize([base, base.merge("type" => nil)])
    expect(tickets.map { |t| t["type"] }).to eq(%w[TASK TASK])
  end

  {
    "schema" => "migration", "data_migration" => "backfill", "Data" => "backfill", "feature" => "code",
    "read switch" => "switch", "contract" => "cleanup", "documentation" => "docs", "dual-write" => "dual_write"
  }.each do |given, expected|
    it "reads kind #{given.inspect} as #{expected}" do
      tickets, = normalize([base.merge("kind" => given)])
      expect(tickets.first["kind"]).to eq(expected)
    end
  end

  it "falls back to code for an unknown kind and says so" do
    tickets, report = normalize([base.merge("kind" => "refactor")])
    expect(tickets.first["kind"]).to eq("code")
    expect(report.fixes).to include("T1: kind \"refactor\" read as code")
  end

  it "prefixes migration and backfill titles" do
    tickets, report = normalize([base.merge("kind" => "migration", "title" => "Add formable to forms"),
                                 base.merge("kind" => "backfill", "title" => "migration: fill formable")])
    expect(tickets.map { |t| t["title"] }).to eq(["Migration: Add formable to forms", "Data migration: fill formable"])
    expect(report.fixes.size).to eq(2)
  end

  it "leaves a correct prefix alone" do
    tickets, report = normalize([base.merge("kind" => "migration", "title" => "Migration: Add x")])
    expect(tickets.first["title"]).to eq("Migration: Add x")
    expect(report.fixes).to be_empty
  end

  [[4, 5], [6, 8], [13, 8], [0, 1]].each do |given, expected|
    it "rounds estimate #{given} up the scale to #{expected}" do
      tickets, = normalize([base.merge("estimate" => given)])
      expect(tickets.first["estimate"]).to eq(expected)
    end
  end

  it "reads estimates written as text" do
    tickets, = normalize([base.merge("estimate" => "3 points")])
    expect(tickets.first["estimate"]).to eq(3)
  end

  it "keeps a missing estimate missing, for the guard to report" do
    tickets, = normalize([base.merge("estimate" => nil)])
    expect(tickets.first["estimate"]).to be_nil
  end

  it "splits criteria given as text and strips bullets" do
    tickets, = normalize([base.merge("acceptance_criteria" => "- Forms load\n* Fields save\n")])
    expect(tickets.first["acceptance_criteria"]).to eq(["Forms load", "Fields save"])
  end

  it "normalizes table names" do
    tickets, = normalize([base.merge("touches" => ["`Forms`", "fields"])])
    expect(tickets.first["touches"]).to eq(%w[forms fields])
  end
end
