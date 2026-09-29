# frozen_string_literal: true

RSpec.describe PlanDriven::Guards::PrGuard do
  let(:plan) { create_ticketed_plan(status: "in_development", ticket_status: "pr_open") }
  let(:ticket) { plan.ticket!("T3") }
  let(:pull) { { "title" => "[#{plan.key}/T3] Backfill formable", "body" => "Closes #13" } }
  let(:files) do
    [{ "filename" => "db/migrate/20260929_backfill_formable.rb", "status" => "added", "additions" => 30, "deletions" => 0 },
     { "filename" => "db/schema.rb", "status" => "modified", "additions" => 1, "deletions" => 1 },
     { "filename" => "spec/migrations/backfill_formable_spec.rb", "status" => "added", "additions" => 40,
       "deletions" => 0 },
     { "filename" => "features/#{plan.slug}/t3.feature", "status" => "added", "additions" => 12, "deletions" => 0 }]
  end
  let(:features) { { "features/#{plan.slug}/t3.feature" => feature_for(ticket) } }
  let(:checks) { [{ "name" => "CI", "status" => "completed", "conclusion" => "success" }] }

  before { ticket.update!(issue_number: 13) }

  def check(**overrides)
    described_class.new(ticket, pull: pull, files: files, checks: checks, features: features, **overrides).call
  end

  it "passes a pull request that does what the ticket asked" do
    report = check
    expect(report.errors).to eq([])
    expect(report.warnings).to eq([])
    expect(report.passes).to include("Refers to #{plan.key}/T3 and closes #13", "4 files, 84 changed lines (limit 800)",
                                     "2 spec and feature files changed", "CI is green: CI")
  end

  it "warns when the PR doesn't reference the ticket or close its issue" do
    report = check(pull: { "title" => "Backfill", "body" => "" })
    expect(report.warnings).to include("The PR doesn't mention #{plan.key}/T3", "The PR doesn't close issue #13")
  end

  it "accepts other closing keywords" do
    expect(check(pull: pull.merge("body" => "Resolves #13")).warnings).to eq([])
  end

  it "rejects a PR above the size limit" do
    big = files + [{ "filename" => "app/models/form.rb", "status" => "modified", "additions" => 900, "deletions" => 0 }]
    expect(check(files: big).errors).to include(a_string_matching(/changes 984 lines, above the limit of 800/))
  end

  it "requires specs" do
    expect(check(files: files.first(2)).errors).to include("The PR has no spec or feature changes")
  end

  it "doesn't require specs when the project turns that off" do
    config = PlanDriven::Configuration.new.tap do |c|
      c.require_specs_in_pr = false
      c.cucumber = false
    end
    expect(check(files: files.first(2), config: config).errors).to eq([])
  end

  it "rejects a migration in a code ticket" do
    code = plan.ticket!("T2")
    code.update!(issue_number: nil)
    report = described_class.new(code, pull: { "title" => "#{plan.key}/T2" }, files: files, checks: checks,
                                       features: { "f.feature" => feature_for(code) }).call
    expect(report.errors).to include(a_string_matching(/A dual_write ticket adds a migration/))
  end

  it "warns when a migration ticket also changes application code" do
    migration = plan.ticket!("T1")
    changed = files + [{ "filename" => "app/models/form.rb", "status" => "modified", "additions" => 2,
                         "deletions" => 0 }]
    report = described_class.new(migration, pull: { "title" => "#{plan.key}/T1" }, files: changed, checks: checks,
                                            features: { "f.feature" => feature_for(migration) }).call
    expect(report.warnings).to include("A migration ticket also changes app/models/form.rb")
  end

  it "warns when a migration lands without a schema change" do
    expect(check(files: files.reject { |f| f["filename"] == "db/schema.rb" }).warnings)
      .to include("A migration was added but db/schema.rb didn't change")
  end

  describe "acceptance scenarios" do
    it "requires a scenario tagged with the ticket" do
      expect(check(features: {}).errors).to eq(["No Cucumber scenario is tagged #{ticket.feature_tag}"])
    end

    it "requires a scenario for every criterion" do
      expect(check(features: { "t3.feature" => feature_for(ticket, criteria: 1) }).errors)
        .to eq(["Acceptance criterion 2 has no scenario tagged #{ticket.feature_tag} @ac-2"])
    end

    it "ignores scenarios tagged for another ticket" do
      other = feature_for(plan.ticket!("T4")).sub("@ac-1", "@ac-1 @ac-2")
      expect(check(features: { "t4.feature" => other }).errors).to eq(["No Cucumber scenario is tagged #{ticket.feature_tag}"])
    end
  end

  describe "CI" do
    it "rejects failed checks" do
      failed = [{ "name" => "rspec", "status" => "completed", "conclusion" => "failure" }]
      expect(check(checks: failed).errors).to eq(["CI check \"rspec\" failure"])
    end

    it "warns about running checks and missing checks" do
      expect(check(checks: [{ "name" => "rspec",
                              "status" => "in_progress" }]).warnings).to eq(["1 CI check(s) still running"])
      expect(check(checks: []).warnings).to eq(["No CI checks have reported on this PR yet"])
    end

    it "accepts skipped and neutral checks" do
      ok = %w[skipped neutral].map do |conclusion|
        { "name" => conclusion, "status" => "completed", "conclusion" => conclusion }
      end
      expect(check(checks: ok).errors).to eq([])
    end
  end
end
