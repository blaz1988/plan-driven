# frozen_string_literal: true

RSpec.describe PlanDriven::Guards::PlanGuard do
  def check(sections)
    described_class.new(sections, schema: schema).call
  end

  it "passes a complete plan that describes the real schema" do
    report = check(all_sections)
    expect(report.errors).to eq([])
    expect(report.warnings).to eq([])
  end

  it "reports every empty required section" do
    report = check(all_sections.except("why", "testing"))
    expect(report.errors).to include("Why is empty", "Testing is empty")
  end

  it "reports a section that is too thin" do
    report = check(all_sections.merge("architecture" => "Add a column."))
    expect(report.errors).to include(a_string_matching(/Architectural changes is too thin \(3 words, at least 40\)/))
  end

  it "ignores optional sections that are empty" do
    expect(check(all_sections.merge("when" => "", "monitoring" => "")).errors).to eq([])
  end

  it "warns about placeholders left in the text" do
    report = check(all_sections.merge("risks" => "#{Fixtures::DRAFTED["risks"]}\n- TBD: rollout risk"))
    expect(report.warnings).to include("Risks still contains a placeholder (TBD)")
  end

  it "requires a risk level in the security section" do
    report = check(all_sections.merge("security" => "Access goes through the existing policies, nothing changes there."))
    expect(report.errors).to include(a_string_matching(/doesn't state a risk level/))
  end

  %w[LOW MEDIUM HIGH].each do |level|
    it "accepts risk level #{level}" do
      text = "Policies are unchanged for every role involved.\n\n| Risk Level | #{level} |"
      expect(check(all_sections.merge("security" => text)).errors).to eq([])
    end
  end

  describe "existing data structure" do
    def existing(text)
      check(all_sections.merge("existing_data_structure" => "#{Fixtures::DRAFTED["existing_data_structure"]}\n\n#{text}"))
    end

    it "rejects a model that doesn't exist" do
      expect(existing("`Questionnaire` stores the questions.").errors)
        .to include("Existing Data Structure describes `Questionnaire` as existing, but there's no such model")
    end

    it "rejects a model file that isn't in the app" do
      expect(existing("See app/models/questionnaire.rb.").errors)
        .to include("Existing Data Structure cites app/models/questionnaire.rb, which isn't in the app")
    end

    it "rejects a column the table doesn't have" do
      expect(existing("`forms.formable_type` holds the owner.").errors)
        .to include("Existing Data Structure mentions `forms.formable_type`, but forms has no formable_type column")
    end

    it "accepts real columns and known Ruby constants" do
      expect(existing("`fields.value_type` is a `String`; see `ActiveRecord::Base`.").errors).to eq([])
    end

    it "ignores columns of tables that aren't in the schema, since they may be new" do
      expect(existing("`snapshots.data` will hold it.").errors).to eq([])
    end
  end

  it "includes the migration guard's findings" do
    report = check(all_sections.merge("database_changes" => "Remove the business_process_id column from forms."))
    expect(report.errors).to include(a_string_matching(/remove or rename a column or table in one step/))
  end
end
