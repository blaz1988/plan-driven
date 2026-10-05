# frozen_string_literal: true

module Fixtures
  ANSWERS = {
    "what" => "Forms get polymorphic ownership so a form can belong to a Business Process or be snapshotted " \
              "onto a Project, and the form builder gains new field types across every form.",
    "why" => "Today a form can only belong to a Business Process, so project questionnaires can't keep a " \
             "snapshot of the form they were answered with.",
    "where" => "Form builder settings, project questionnaires",
    "who" => "Team Jarvis",
    "when" => "Q4",
    "background" => "PRD: Form builder field types",
    "out_of_scope" => "Facility forms"
  }.freeze

  DRAFTED = {
    "existing_data_structure" => "### Form (`app/models/form.rb`)\n`Form` belongs to `BusinessProcess` through " \
                                 "`forms.business_process_id`. Forms have a `forms.type` and a `forms.name`.\n\n" \
                                 "### Field (`app/models/field.rb`)\n`Field` stores `fields.name`, `fields.value_type` " \
                                 "and `fields.required` for every field on a form. Fields are rendered in the " \
                                 "order the builder saved them.",
    "architecture" => "Forms move from a single business_process_id owner to a polymorphic formable owner. During " \
                      "rollout both owners are written, existing forms are backfilled, reads switch to formable, " \
                      "and only then is the legacy column removed. Projects keep a snapshot of the form they use.",
    "database_changes" => "### forms\nAdd `formable_type` (string, nullable) and `formable_id` (bigint, nullable) " \
                          "with an index on (type, formable_type, formable_id).\n\n```ruby\n" \
                          "add_reference :forms, :formable, polymorphic: true, index: false\n" \
                          "add_index :forms, [:type, :formable_type, :formable_id]\n```\n\nAfter the backfill, add " \
                          "`business_process_id` to `ignored_columns`, deploy, then remove the column in a later " \
                          "migration and add NOT NULL to formable_type and formable_id.",
    "application_changes" => "### Form\nWrite business_process_id and formable together on create. Read forms " \
                             "through formable once the backfill is done.\n\n### Project questionnaire\nCopy the " \
                             "form structure into a snapshot when a project is created, so later edits don't change it. " \
                             "Legacy forms keep working unchanged.",
    "infrastructure_changes" => "No new queues or services. The switch to formable reads ships behind a feature flag.",
    "risks" => "- Forms without an owner after the backfill: the backfill is idempotent and re-runnable.\n" \
               "- Reads switched too early: the switch ships after the backfill is verified.",
    "performance" => "The backfill runs in batches of 1,000 and the new composite index keeps type-scoped lookups fast.",
    "security" => "Form access still goes through the Business Process policy; formable doesn't widen it.\n\n" \
                  "Risk Level: MEDIUM. Ownership changes touch every form read.",
    "monitoring" => "Watch errors on form loading and the backfill job's duration.",
    "outstanding_questions" => "Should facility forms follow the same model later?",
    "testing" => "- Model specs for dual ownership\n- Backfill spec that re-runs safely\n- Request specs for form " \
                 "loading through formable\n- Project questionnaire snapshot specs, including legacy forms"
  }.freeze

  TICKETS = [
    { "key" => "T1", "title" => "Add polymorphic ownership to forms", "kind" => "migration", "type" => "TASK",
      "description" => "Add formable_type and formable_id to forms with a composite index.",
      "acceptance_criteria" => ["Forms table has nullable formable_type and formable_id columns",
                                "Existing forms still load through business_process_id"],
      "estimate" => 2, "depends_on" => [], "touches" => ["forms"] },
    { "key" => "T2", "title" => "Write both owners for new forms", "kind" => "dual_write", "type" => "STORY",
      "story" => "I want new forms to store both owners, so that data stays consistent during the migration.",
      "description" => "Set formable alongside business_process_id when a form is created.",
      "acceptance_criteria" => ["A new form stores business_process_id and formable together"],
      "estimate" => 3, "depends_on" => ["T1"], "touches" => ["forms"] },
    { "key" => "T3", "title" => "Backfill formable for existing forms", "kind" => "backfill", "type" => "TASK",
      "description" => "Populate formable from business_process_id for every existing form, in batches.",
      "acceptance_criteria" => ["Every existing form has formable set to its Business Process",
                                "Running the backfill twice changes nothing the second time"],
      "estimate" => 2, "depends_on" => ["T1"], "touches" => ["forms"] },
    { "key" => "T4", "title" => "Read forms through formable", "kind" => "switch", "type" => "TASK",
      "description" => "Load forms by formable and add business_process_id to ignored_columns.",
      "acceptance_criteria" => ["Forms load through formable in every screen that shows them"],
      "estimate" => 3, "depends_on" => %w[T2 T3], "touches" => ["forms"] },
    { "key" => "T5", "title" => "Migration: Remove legacy business_process_id column from forms", "kind" => "migration",
      "type" => "TASK", "description" => "Drop the column and add NOT NULL to formable columns.",
      "acceptance_criteria" => ["The forms table no longer has a business_process_id column"],
      "estimate" => 1, "depends_on" => ["T4"], "touches" => ["forms"] }
  ].freeze

  def root = @root
  def answers = ANSWERS.dup
  def drafted_sections = DRAFTED.dup
  def all_sections = ANSWERS.merge(DRAFTED)
  def tickets_reply = { "tickets" => TICKETS.map(&:dup) }

  def plan_reply(sections = DRAFTED)
    { "sections" => sections, "assumptions" => ["Business Process remains the default owner"] }
  end

  def schema
    @schema ||= PlanDriven::SchemaContext.new(root: root)
  end

  def create_plan(status: "draft", sections: all_sections)
    PlanDriven::Plan.create!(title: "Polymorphic form ownership", sections: sections, interview: ANSWERS,
                             created_by: "Ada <ada@example.com>", status: status)
  end

  def create_ticketed_plan(status: "tickets_approved", ticket_status: "approved")
    plan = create_plan(status: status)
    TICKETS.each_with_index do |ticket, index|
      plan.tickets.create!(key: ticket["key"], position: index, title: ticket["title"], kind: ticket["kind"],
                           ticket_type: ticket["type"], story: ticket["story"], description: ticket["description"],
                           acceptance_criteria: ticket["acceptance_criteria"], estimate: ticket["estimate"],
                           depends_on: ticket["depends_on"], touches: ticket["touches"], status: ticket_status)
    end
    plan.tickets.reset
    plan
  end

  def normalized_tickets(tickets = TICKETS)
    PlanDriven::Guards::TicketNormalizer.new(tickets.map(&:dup)).call(PlanDriven::Guards::Report.new)
  end

  def feature_for(ticket, criteria: ticket.criteria.size)
    scenarios = (1..criteria).map do |number|
      "  @ac-#{number}\n  Scenario: criterion #{number}\n    Given a form\n    Then it works\n"
    end
    "#{ticket.feature_tag}\nFeature: #{ticket.title}\n\n#{scenarios.join("\n")}"
  end

  def cucumber_json(scenarios)
    features = scenarios.group_by { |scenario| scenario[:feature_tag] }.map do |tag, items|
      { "uri" => "features/#{tag.delete("@")}.feature", "tags" => [{ "name" => tag }],
        "elements" => items.each_with_index.map do |item, index|
          { "type" => "scenario", "name" => item[:name] || "scenario #{index}", "line" => 3 + index,
            "tags" => item[:tags].map { |name| { "name" => name } },
            "steps" => [{ "result" => { "status" => item[:status] || "passed" } }] }
        end }
    end
    JSON.generate(features)
  end

  def delivery(llm: FakeLLM.new, github: FakeGitHub.new, agents: FakeAgents.new, actor: "Ada <ada@example.com>")
    PlanDriven::Delivery.new(actor: actor, llm: llm, schema: schema, github: github, agents: agents)
  end
end
