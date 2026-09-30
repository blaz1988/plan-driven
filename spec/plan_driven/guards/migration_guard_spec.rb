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

  it "rejects a one-step rename even when the plan also has expand and contract steps" do
    text = "### Step 1: Expand\n\nCreate table `categories`.\n\n### Step 2: Switch reads\n\n" \
           "Rename column `name` to `title` on `forms`.\n\n### Step 3: Contract\n\nNothing to remove."
    expect(check(text).errors.first).to match(/in one step \("Rename column `name` to `title` on `forms`/)
  end

  it "rejects a removal in migration code under an expand step" do
    text = "### Step 1: Expand\n\n```ruby\ndef change\n  remove_column :events, :category\nend\n```"
    expect(check(text).errors.first).to match(/in one step/)
  end

  it "accepts a removal in migration code under a contract step" do
    text = "### Step 1: Expand\n\nAdd `category_id` to `events`.\n\n### Step 4: Contract (later deploy)\n\n" \
           "```ruby\n# Remove the old column\nremove_column :events, :category\n```"
    expect(check(text).errors).to eq([])
  end

  it "reads headings and negated sentences as context, not changes" do
    text = "### Removed or renamed columns\n\nNone. No column is removed or renamed, so `ignored_columns` " \
           "isn't needed. There is no `events.category` string column."
    expect(check(text).errors).to eq([])
  end

  it "accepts dropping a table the plan creates, and rollback notes" do
    text = "New table: `rsvps`.\n\n`drop_table :rsvps` is reversible.\n\n### Rollback\n\nremove_column :forms, :x"
    expect(check(text).errors).to eq([])
  end

  it "doesn't let a new table excuse a change to an existing one" do
    text = "New table: `rsvps`.\n\nRename column `name` to `title` on `forms`, next to rsvps."
    expect(check(text).errors.first).to match(/in one step/)
  end

  it "still rejects a removal followed by an unrelated negation" do
    expect(check("Drop the legacy_name column; no code reads it.").errors.first).to match(/in one step/)
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
