# frozen_string_literal: true

RSpec.describe PlanDriven::DataModel do
  def model(code, prose: "")
    described_class.new("#{prose}\n\n```ruby\n#{code}\n```\n", schema: schema)
  end

  def table(model, name)
    model.tables.find { |t| t.name == name }
  end

  def statuses(table)
    table.columns.to_h { |column| [column.name, column.status] }
  end

  it "draws a new table, its references and the tables they point to" do
    result = model(<<~RUBY)
      class CreateApprovals < ActiveRecord::Migration[8.0]
        def change
          create_table :approvals do |t|
            t.references :form, null: false, foreign_key: true
            t.references :approver, foreign_key: { to_table: :business_processes }
            t.string :decision, :note, null: false
            t.timestamps
          end
        end
      end
    RUBY
    approvals = table(result, "approvals")
    expect(approvals.status).to eq(:new)
    expect(statuses(approvals).keys).to eq(%w[id form_id approver_id decision note created_at updated_at])
    expect(statuses(approvals).values.uniq).to eq([:added])
    expect(table(result, "forms").status).to eq(:context)
    expect(result.links).to contain_exactly(%w[approvals form_id forms], %w[approvals approver_id business_processes])
  end

  it "marks what changes on an existing table" do
    result = model(<<~RUBY)
      add_reference :forms, :formable, polymorphic: true, index: false
      change_column_null :forms, :name, false
      rename_column :forms, :type, :kind
      remove_column :forms, :business_process_id
    RUBY
    forms = table(result, "forms")
    expect(forms.status).to eq(:changed)
    expect(statuses(forms)).to include("formable_id" => :added, "formable_type" => :added, "name" => :changed,
                                       "kind" => :renamed, "business_process_id" => :removed, "id" => :kept)
    expect(forms.column("kind").was).to eq("type")
    expect(result.tables.map(&:name)).to eq(%w[forms business_processes])
    expect(result.to_svg).to include('stroke-dasharray="5 4"')
  end

  it "reads change_table blocks, dropped and renamed tables" do
    result = model(<<~RUBY)
      change_table :fields do |t|
        t.integer :position
        t.remove :value_type
        t.rename :required, :mandatory
      end
      drop_table :projects
      rename_table :business_processes, :workflows
    RUBY
    expect(statuses(table(result, "fields"))).to include("position" => :added, "value_type" => :removed,
                                                         "mandatory" => :renamed)
    expect(table(result, "projects").status).to eq(:removed)
    expect(table(result, "workflows")).to have_attributes(status: :changed, was: "business_processes")
  end

  it "stays the same once the plan's migration has run" do
    result = model("create_table :forms do |t|\n  t.string :name\nend\nadd_column :fields, :name, :string")
    expect(table(result, "forms").status).to eq(:new)
    expect(statuses(table(result, "fields"))["name"]).to eq(:added)
  end

  it "draws nothing from prose, or from code that isn't Ruby" do
    prose = described_class.new("Add `formable_type` to forms.\n\n```sql\nALTER TABLE forms ADD x int;\n```",
                                schema: schema)
    expect(prose).not_to be_drawable
    expect(prose).not_to be_code
  end

  it "draws an SVG with every change marked" do
    svg = model("create_table :approvals do |t|\n  t.references :form\nend\nremove_column :forms, :name").to_svg
    expect(svg).to start_with("<svg").and include("Data model", "approvals", "form_id", "Referenced, unchanged",
                                                  'text-decoration="line-through"', "marker-end", "1 new, 1 changed")
  end

  it "writes the diagram beside the plan, and removes it when it's turned off" do
    plan = create_plan
    dir = PlanDriven::Renderer.directory(plan)
    paths = PlanDriven::Renderer.write_plan(plan, schema: schema)
    expect(dir.join(described_class::FILE).read).to include("formable_type")
    expect(paths[:markdown].read).to include("![Data model: the tables this plan creates, changes or removes]" \
                                             "(data-model.svg)\n\n### forms")
    expect(paths[:html].read).to include('<figure class="chart"><svg')

    PlanDriven.configuration.data_model_diagram = false
    paths = PlanDriven::Renderer.write_plan(plan, schema: schema)
    expect(dir.join(described_class::FILE)).not_to exist
    expect(paths[:markdown].read).not_to include("data-model.svg")
  end

  it "asks the drafting model for migration code, and warns when a plan has none" do
    drafter = PlanDriven::Drafter.new(llm: FakeLLM.new, schema: schema)
    expect(drafter.system_prompt).to include("write every schema change as Rails migration code")

    prose = all_sections.merge("database_changes" => "### forms\nAdd `formable_type` (string) to `forms`.")
    report = PlanDriven::Guards::PlanGuard.new(prose, schema: schema).call
    expect(report.warnings).to include(a_string_matching(/without migration code, so the data model diagram/))
    expect(PlanDriven::Guards::PlanGuard.new(all_sections, schema: schema).call.passes)
      .to include("The data model diagram shows 1 table(s) the plan changes")

    PlanDriven.configuration.data_model_diagram = false
    expect(PlanDriven::Drafter.new(llm: FakeLLM.new, schema: schema).system_prompt).not_to include("migration code")
    expect(PlanDriven::Guards::PlanGuard.new(prose, schema: schema).call.warnings).to eq([])
  end
end
