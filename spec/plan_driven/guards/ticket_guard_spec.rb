# frozen_string_literal: true

RSpec.describe PlanDriven::Guards::TicketGuard do
  def check(tickets, sections: all_sections)
    described_class.new(tickets, plan_sections: sections, schema: schema).call
  end

  def with(key, changes)
    normalized_tickets.map { |ticket| ticket["key"] == key ? ticket.merge(changes) : ticket }
  end

  it "passes the expand-and-contract breakdown" do
    report = check(normalized_tickets)
    expect(report.errors).to eq([])
    expect(report.warnings).to eq([])
  end

  it "rejects an empty breakdown" do
    expect(check([]).errors).to eq(["There are no tickets"])
  end

  it "requires acceptance criteria" do
    expect(check(with("T3", "acceptance_criteria" => [])).errors).to include("T3 has no acceptance criteria")
  end

  it "rejects criteria too short to test" do
    expect(check(with("T3", "acceptance_criteria" => ["Works"])).errors)
      .to include("T3 acceptance criterion 1 is too short to test: \"Works\"")
  end

  it "warns about a ticket with many criteria" do
    criteria = (1..9).map { |n| "Criterion number #{n} holds" }
    expect(check(with("T3",
                      "acceptance_criteria" => criteria)).warnings).to include(a_string_matching(/9 acceptance criteria/))
  end

  it "requires a story to say why" do
    expect(check(with("T2", "story" => "I want both owners.")).errors).to include("T2 is a story without \"so that\"")
  end

  it "requires a description and a title" do
    errors = check(with("T3", "description" => "", "title" => "")).errors
    expect(errors).to include("T3 has no description", "T3 has no title")
  end

  it "rejects an estimate above the limit" do
    expect(check(with("T4", "estimate" => 8)).errors).to include(a_string_matching(/T4 is estimated at 8.*split it/))
  end

  it "requires an estimate" do
    expect(check(with("T4", "estimate" => nil)).errors).to include("T4 has no estimate")
  end

  it "rejects unknown dependencies and self-dependencies" do
    errors = check(with("T4", "depends_on" => %w[T4 T9])).errors
    expect(errors).to include("T4 depends on unknown T9", "T4 depends on itself")
  end

  it "rejects a dependency cycle" do
    errors = check(with("T1", "depends_on" => ["T4"])).errors
    expect(errors).to include(a_string_matching(/Dependencies form a cycle: T1 -> T4 -> T2 -> T1|cycle/))
  end

  it "rejects code tickets split by layer instead of behaviour" do
    layered = normalized_tickets + [
      { "key" => "T6", "title" => "Model: Add Question", "kind" => "code" },
      { "key" => "T7", "title" => "Controller: Add QuestionsController", "kind" => "code" }
    ].map { |t| t.merge("type" => "TASK", "description" => "d", "acceptance_criteria" => ["It works for users"], "estimate" => 2, "depends_on" => ["T1"], "touches" => ["forms"]) }
    expect(check(layered).errors).to include(a_string_matching(/T6, T7 split the work by layer/))
    expect(check(layered.first(6)).errors).to eq([])
  end

  describe "expand before contract" do
    it "requires code that touches a table to build on its migration" do
      expect(check(with("T2", "depends_on" => [])).errors)
        .to include("T2 (dual_write) touches forms but doesn't depend on T1 (migration), which must merge first")
    end

    it "accepts a dependency that is only transitive" do
      expect(check(with("T4", "depends_on" => %w[T2 T3])).errors).to eq([])
    end

    it "treats a migration that removes a column as cleanup, after the backfill and the switch" do
      errors = check(with("T5", "depends_on" => ["T1"])).errors
      expect(errors).to include(a_string_matching(/T5 \(cleanup\) touches forms but doesn't depend on T3 \(backfill\)/),
                                a_string_matching(/T5 \(cleanup\) touches forms but doesn't depend on T4 \(switch\)/))
    end

    it "doesn't require other tickets to depend on the removal" do
      expect(check(normalized_tickets).errors).to eq([])
    end

    it "only compares tickets that touch the same table" do
      tickets = with("T2", "depends_on" => [], "touches" => ["projects"])
      expect(check(tickets).errors).to eq([])
    end
  end

  describe "coverage" do
    it "warns when the plan changes a table no ticket touches" do
      sections = all_sections.merge("database_changes" => "#{Fixtures::DRAFTED["database_changes"]}\n\nNew table: `snapshots`.")
      expect(check(normalized_tickets, sections: sections).warnings)
        .to include("Database changes mention snapshots, but no ticket touches it")
    end

    it "counts tables the plan changes, not tables it names as staying the same" do
      base = Fixtures::DRAFTED["database_changes"]
      unchanged = all_sections.merge("database_changes" => "#{base}\n\n### Tables not changed\n" \
                                                           "`projects` keeps its current columns and indexes.")
      changed = all_sections.merge("database_changes" => "#{base}\n\nAdd an `archived_at` column to `projects`.")

      expect(check(normalized_tickets, sections: unchanged).warnings.grep(/projects/)).to eq([])
      expect(check(normalized_tickets, sections: changed).warnings)
        .to include("Database changes mention projects, but no ticket touches it")
    end

    it "warns when a ticket touches a table that exists nowhere" do
      expect(check(with("T3", "touches" => %w[forms widgets])).warnings)
        .to include("A ticket touches widgets, which isn't in the schema or the plan's database changes")
    end
  end
end
