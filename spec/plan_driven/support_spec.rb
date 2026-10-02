# frozen_string_literal: true

RSpec.describe "Supporting pieces" do
  describe PlanDriven::JsonReply do
    it "reads fenced JSON and JSON surrounded by prose" do
      expect(described_class.parse("```json\n{\"a\": 1}\n```")).to eq("a" => 1)
      expect(described_class.parse("Here it is: {\"a\": {\"b\": 2}} Hope that helps")).to eq("a" => { "b" => 2 })
    end

    it "raises on text without JSON" do
      expect { described_class.parse("no json") }.to raise_error(PlanDriven::InvalidResponseError)
    end
  end

  describe PlanDriven::Gherkin do
    let(:text) do
      <<~GHERKIN
        @pd-1-t1
        Feature: Formable columns

          Background:
            Given a business process

          @ac-1
          Scenario: Columns exist
            Given the migration ran
            Then forms has formable_type

          @ac-2 @slow
          Scenario Outline: Legacy forms load
            Given a form "<name>"
            Examples:
              | name |
              | A    |
      GHERKIN
    end

    it "parses scenarios with inherited tags" do
      feature = described_class.parse(text, path: "features/t1.feature")
      expect(feature.name).to eq("Formable columns")
      expect(feature.scenarios.map(&:name)).to eq(["Columns exist", "Legacy forms load"])
      expect(feature.scenarios.last.tags).to eq(%w[@pd-1-t1 @ac-2 @slow])
      expect(feature.scenarios.first.steps).to eq(["Given the migration ran", "Then forms has formable_type"])
      expect(feature.scenarios.first.line).to eq(8)
    end
  end

  describe PlanDriven::Template do
    let(:template) { PlanDriven::Template.default }

    it "asks the team what only they know and drafts the rest" do
      expect(template.asked.map(&:key)).to eq(%w[what why where who when background out_of_scope])
      expect(template.drafted.map(&:key)).to include("existing_data_structure", "database_changes", "security",
                                                     "testing")
    end

    it "gives every drafted section guidance and every asked section a question" do
      expect(template.drafted.map(&:guidance)).to all(be_present)
      expect(template.asked.map(&:question)).to all(be_present)
    end
  end

  describe PlanDriven::SchemaContext do
    it "describes the application's tables, not the gem's" do
      expect(schema.tables).to include("forms", "fields")
      expect(schema.tables.grep(/plan_driven/)).to be_empty
      expect(schema.column?("forms", "business_process_id")).to be(true)
      expect(schema.model?("BusinessProcess")).to be(true)
      expect(schema.to_prompt).to include("forms", "business_process_id")
    end
  end

  describe PlanDriven::Credentials do
    around do |example|
      saved = PlanDriven::Credentials::KEYS.values.to_h { |env| [env, ENV.delete(env)] }
      example.run
    ensure
      saved.each { |env, value| value ? ENV[env] = value : ENV.delete(env) }
    end

    before { allow(PlanDriven::Credentials).to receive(:gh_token).and_return(nil) }

    it "stores keys in a private file" do
      path = PlanDriven::Credentials.store(:cursor_api_key, "key_abc")
      expect(File.stat(path).mode & 0o777).to eq(0o600)
      expect(PlanDriven::Credentials.fetch(:cursor_api_key)).to eq("key_abc")
      expect(PlanDriven::Credentials.source(:cursor_api_key)).to eq(path)
    end

    it "prefers the environment" do
      PlanDriven::Credentials.store(:openai_api_key, "from-file")
      ENV["OPENAI_API_KEY"] = "from-env"
      expect(PlanDriven::Credentials.fetch(:openai_api_key)).to eq("from-env")
      expect(PlanDriven::Credentials.source(:openai_api_key)).to eq("environment (OPENAI_API_KEY)")
    end

    it "falls back to the GitHub CLI for a token" do
      allow(PlanDriven::Credentials).to receive(:gh_token).and_return("gho_cli")
      expect(PlanDriven::Credentials.fetch(:github_token)).to eq("gho_cli")
    end

    it "refuses unknown names" do
      expect { PlanDriven::Credentials.store(:aws, "x") }.to raise_error(ArgumentError)
    end
  end

  describe PlanDriven::Repository do
    it "reads the GitHub slug from SSH and HTTPS remotes" do
      PlanDriven.configuration.github_repository = nil
      {
        "git@github.com:acme/app.git" => "acme/app",
        "git@github.com-work:acme/app.git" => "acme/app",
        "https://github.com/acme/app" => "acme/app",
        "https://github.com/acme/app.js.git" => "acme/app.js",
        "git@gitlab.com:acme/app.git" => nil
      }.each do |remote, slug|
        expect(PlanDriven::Repository.parse(remote)).to eq(slug)
      end
    end

    it "prefers the configured repository" do
      expect(PlanDriven::Repository.slug).to eq("acme/app")
    end
  end

  describe PlanDriven::AgentPrompt do
    let(:plan) { create_ticketed_plan }
    let(:ticket) { plan.ticket!("T3") }

    it "tells the agent what done means" do
      ticket.update!(issue_number: 13)
      PlanDriven.configuration.team_rules = ["Use service objects in app/services"]
      prompt = described_class.new(ticket)
      text = prompt.to_s
      expect(text).to include("PD-1/T3", "Every existing form has formable set to its Business Process",
                              "features/#{plan.slug}/t3.feature", "`@pd-1-t3`", "`@ac-N`", "Closes #13",
                              "Already merged into the base branch: T1 Add polymorphic ownership to forms",
                              "Use service objects in app/services", Fixtures::DRAFTED["database_changes"].lines.first.strip)
      expect(prompt.pr_title).to eq("[PD-1/T3] Backfill formable for existing forms")
    end

    it "follows the settings for tests and migrations" do
      code = plan.ticket!("T2")
      text = described_class.new(code).to_s
      expect(text).to include("run only the specs and features for the files you change",
                              "Schema changes only in migration tickets; this ticket is a dual_write ticket.")

      PlanDriven.configuration.targeted_tests = false
      PlanDriven.configuration.separate_migrations = false
      text = described_class.new(code).to_s
      expect(text).not_to include("run only the specs")
      expect(text).to include("add it as a migration in this pull request, with db/schema.rb")
    end
  end

  describe PlanDriven::Renderer do
    let(:plan) { create_ticketed_plan }

    it "writes the plan like the team's Confluence template" do
      markdown = PlanDriven::Renderer::Markdown.plan(plan)
      expect(markdown).to include("# PD-1: Polymorphic form ownership", "# Overview\n\n## What", "# Architectural changes",
                                  "## Database changes", "| T4 | Read forms through formable | TASK | switch | 3 | T2, T3 |",
                                  "**Estimated total: 11 points**", "Risk Level: MEDIUM", "# Sign-off",
                                  "| Review | pending |")
    end

    it "writes Markdown and HTML to docs/plans" do
      paths = PlanDriven::Renderer.write_plan(plan)
      expect(paths[:markdown].to_s).to end_with("docs/plans/pd-1-polymorphic-form-ownership/plan.md")
      html = paths[:html].read
      expect(html).to include("<h1>PD-1: Polymorphic form ownership</h1>", "<table>",
                              "<code>forms.business_process_id</code>")
      expect(paths[:pdf]).to be_nil
    end

    it "uses the configured PDF renderer" do
      PlanDriven.configuration.pdf_renderer = ->(_html, pdf) { File.write(pdf, "%PDF") }
      expect(PlanDriven::Renderer.write_plan(plan)[:pdf].read).to eq("%PDF")
    end

    it "escapes HTML in the text" do
      expect(PlanDriven::Renderer::HTML.convert("Use <script> & `a<b`")).to include("&lt;script&gt; &amp;",
                                                                                    "<code>a&lt;b</code>")
    end
  end
end
