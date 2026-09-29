# frozen_string_literal: true

module PlanDriven
  # What a coding agent is told about one ticket. The plan supplies the context, the ticket the
  # scope, and the rules are the same ones PrGuard checks afterwards, so the agent is told in
  # advance exactly what will be verified.
  class AgentPrompt
    CONTEXT_SECTIONS = %w[what why architecture database_changes application_changes security testing].freeze

    def initialize(ticket, config: PlanDriven.configuration)
      @ticket = ticket
      @plan = ticket.plan
      @config = config
    end

    def to_s
      [intro, ticket_block, plan_block, done_block, rules_block, pr_block].compact.join("\n\n")
    end

    def pr_title
      "[#{@ticket.reference}] #{@ticket.title}"
    end

    private

    def intro
      "You are implementing one ticket of an approved implementation plan in this Rails application. " \
        "Implement this ticket only. Other tickets of the plan are handled in their own pull requests."
    end

    def ticket_block
      lines = ["# Ticket #{@ticket.reference}: #{@ticket.title}",
               "Kind: #{@ticket.kind}. Type: #{@ticket.ticket_type}."]
      lines << "\n#{@ticket.story}" if @ticket.story.present?
      lines << "\n#{@ticket.description}"
      lines << "\n## Acceptance criteria"
      @ticket.criteria.each_with_index { |criterion, index| lines << "#{index + 1}. #{criterion}" }
      lines << "\n## Implementation notes\n#{@ticket.implementation_notes}" if @ticket.implementation_notes.present?
      merged = @ticket.dependency_tickets.map { |ticket| "#{ticket.key} #{ticket.title}" }
      lines << "\nAlready merged into the base branch: #{merged.join("; ")}." if merged.any?
      lines.join("\n")
    end

    def plan_block
      sections = CONTEXT_SECTIONS.filter_map do |key|
        text = @plan.section(key).strip
        "## #{@config.template[key]&.title || key}\n#{text}" unless text.empty?
      end
      "# Context from plan #{@plan.key}: #{@plan.title}\n\n#{sections.join("\n\n")}"
    end

    def done_block
      lines = ["# Definition of done"]
      lines << "- Specs cover the change (#{@config.spec_paths.join(", ")}), and the existing suite still passes."
      if @config.cucumber && @ticket.kind != "docs"
        lines << "- Every acceptance criterion has a Cucumber scenario in " \
                 "`#{@config.features_path}/#{@plan.slug}/#{@ticket.key.downcase}.feature`. Tag the feature " \
                 "`#{@ticket.feature_tag}` and each scenario `@ac-N`, where N is the criterion's number above."
        lines << "- If the app has no Cucumber setup yet, add `cucumber-rails` to the test group and run " \
                 "`bin/rails generate cucumber:install` in this pull request."
      end
      lines << "- Keep the change within #{@config.max_pr_changed_lines} changed lines."
      lines.join("\n")
    end

    def rules_block
      rules = ["Follow the conventions already used in this codebase.",
               "Schema changes only in migration tickets; this ticket is a #{@ticket.kind} ticket.",
               "Migrations are additive and reversible. Never remove or rename a column that code still reads.",
               "Don't edit files under #{@config.docs_path}; they are the approved plan.",
               *@config.team_rules]
      "# Rules\n#{rules.map { |rule| "- #{rule}" }.join("\n")}"
    end

    def pr_block
      closes = @ticket.issue_number ? "\n- a line `Closes ##{@ticket.issue_number}`" : ""
      <<~TEXT.strip
        # Pull request
        Title it exactly: #{pr_title}
        In the description include:
        - `#{@ticket.reference}`#{closes}
        - each acceptance criterion as a checklist, with the spec or scenario that proves it
      TEXT
    end
  end
end
