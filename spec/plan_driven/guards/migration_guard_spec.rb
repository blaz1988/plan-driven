# frozen_string_literal: true

RSpec.describe PlanDriven::Guards::MigrationGuard do
  def check(text, adapter: "SQLite")
    allow(schema).to receive(:adapter).and_return(adapter)
    described_class.new(text, schema: schema).call
  end

  DESTRUCTIVE = [
    "Remove the business_process_id column from forms.",
    "Drop the legacy table questionnaires.",
    "Rename column name to title on fields.",
    "remove_column :forms, :business_process_id",
    "rename_table :fields, :form_fields",
    "change_column :fields, :value_type, :integer",
    "Delete the obsolete fields column required."
  ].freeze

  DESTRUCTIVE.each do |text|
    it "rejects a one-step destructive change: #{text}" do
      expect(check(text).errors.first).to match(/in one step/)
    end
  end

  [
    "Add business_process_id to ignored_columns, deploy, then remove the column in a later migration.",
    "Expand: add formable. Contract: drop business_process_id after the backfill.",
    "Remove the column in a later release, once reads have switched."
  ].each do |text|
    it "accepts a staged removal: #{text}" do
      expect(check(text).errors).to eq([])
    end
  end

  it "passes additive changes" do
    expect(check("Add formable_type (string, nullable) to forms.").errors).to eq([])
  end

  it "passes an empty section, which the plan guard reports separately" do
    expect(check("").errors).to eq([])
  end

  it "warns about NOT NULL on an existing table without a default or backfill" do
    report = check("### forms\nAdd `owner_id` bigint, NOT NULL.")
    expect(report.warnings).to include(a_string_matching(/NOT NULL change on existing table forms/))
  end

  it "doesn't mistake a description of the current schema for a change" do
    text = "### Current schema\nforms: `id`, `name` (string, not null).\n\n" \
           "New table: `snapshots` with `form_id` bigint NOT NULL, foreign key to `forms`."
    expect(check(text).warnings).to eq([])
  end

  it "warns about NOT NULL added to an existing table in prose" do
    report = check("Add a `locale` string column, NOT NULL, to the `forms` table.")
    expect(report.warnings).to include(a_string_matching(/NOT NULL change on existing table forms/))
  end

  it "accepts NOT NULL with a default" do
    expect(check("### fields\nAdd `position` integer, null: false, default: 0.").warnings).to eq([])
  end

  it "doesn't warn about NOT NULL on a new table" do
    expect(check("New table: `snapshots` with `data` jsonb NOT NULL.").warnings).to eq([])
  end

  it "warns about a non-concurrent index on PostgreSQL" do
    report = check("### forms\nadd_index on (type, formable_type, formable_id)", adapter: "PostgreSQL")
    expect(report.warnings).to include(a_string_matching(/isn't built concurrently/))
  end

  it "accepts a concurrent index on PostgreSQL" do
    text = "### forms\nadd_index with algorithm: :concurrently and disable_ddl_transaction!"
    expect(check(text, adapter: "PostgreSQL").warnings).to eq([])
  end

  it "doesn't warn about indexes on other databases" do
    expect(check("### forms\nadd_index on (type)").warnings).to eq([])
  end

  it "lists new tables from the text" do
    text = "New table: `snapshots`\ncreate_table :form_versions\n- Create `project_questions` table:\n" \
           "Create a new table `project_answers`\ncreate_table \"tags\""
    guard = described_class.new(text, schema: schema)
    expect(guard.new_tables).to eq(%w[snapshots form_versions project_questions project_answers tags])
  end

  it "lists a table named in a step heading or a migration file" do
    text = "### Step 1 — Expand: create `rsvps`\nMigration file: `db/migrate/<timestamp>_create_badges.rb`.\n" \
           "Create `status` column"
    expect(described_class.new(text, schema: schema).new_tables).to eq(%w[rsvps badges])
  end
end
