# frozen_string_literal: true

module PlanDriven
  # The shape of an implementation plan. The default follows the structure Rails teams already
  # write in Confluence: Overview, Background, Architectural changes, Work overview, Risks,
  # Testing and sign-off. Sections marked `ask` come from the person in the terminal; the rest
  # are drafted by the model from the answers and the real schema, then checked by the guards.
  class Template
    Section = Struct.new(:key, :title, :group, :source, :required, :question, :guidance, :min_words,
                         keyword_init: true) do
      def asked?
        source == :ask
      end

      def drafted?
        source == :draft
      end

      # The question as the interview shows it, in the terminal and in the wizard.
      def prompt
        required ? question.to_s : "#{question} (optional)"
      end
    end

    GROUPS = ["Overview", "Background", "Architectural changes", "Work overview", "Risks", "Testing"].freeze

    attr_reader :sections

    def self.default
      new(DEFAULT_SECTIONS)
    end

    def initialize(sections)
      @sections = sections.map { |section| section.is_a?(Section) ? section : Section.new(**section) }
    end

    def [](key)
      sections.find { |section| section.key == key.to_s }
    end

    def keys
      sections.map(&:key)
    end

    def asked
      sections.select(&:asked?)
    end

    def drafted
      sections.select(&:drafted?)
    end

    def required
      sections.select(&:required)
    end

    def grouped
      GROUPS.to_h { |group| [group, sections.select { |section| section.group == group }] }
    end

    DEFAULT_SECTIONS = [
      { key: "what", title: "What", group: "Overview", source: :ask, required: true, min_words: 15,
        question: "What are we building? Describe the change as the user will see it.",
        guidance: "The change in two or three short paragraphs, in product terms." },
      { key: "why", title: "Why", group: "Overview", source: :ask, required: true, min_words: 10,
        question: "Why now? What problem or gap does it close?",
        guidance: "The problem, the gap or the business reason, as a short list if there are several." },
      { key: "where", title: "Where", group: "Overview", source: :ask, required: true, min_words: 2,
        question: "Where in the product does it land? (modules, screens, APIs)",
        guidance: "The modules, screens, APIs and jobs affected." },
      { key: "who", title: "Who", group: "Overview", source: :ask, required: true, min_words: 1,
        question: "Who owns it? (team, people)", guidance: "Owning team and people." },
      { key: "when", title: "When", group: "Overview", source: :ask, required: false, min_words: 0,
        question: "When is it needed? (date, milestone, or leave empty)", guidance: "Target date or milestone." },
      { key: "background", title: "Background", group: "Background", source: :ask, required: false, min_words: 0,
        question: "Links, PRDs, existing tickets, earlier decisions",
        guidance: "Links, product documents, related tickets and earlier decisions." },
      { key: "existing_data_structure", title: "Existing Data Structure", group: "Background", source: :draft,
        required: true, min_words: 30,
        guidance: "The existing models, tables, columns and associations this change touches, one subsection " \
                  "per model with its file path (for example `app/models/form.rb`). Only describe what exists " \
                  "in the schema you were given." },
      { key: "architecture", title: "Architectural changes", group: "Architectural changes", source: :draft,
        required: true, min_words: 40,
        guidance: "The target design and data flow. Keep the existing execution shape where possible. Explain " \
                  "how legacy data coexists with the new model during rollout." },
      { key: "database_changes", title: "Database changes", group: "Architectural changes", source: :draft,
        required: true, min_words: 20,
        guidance: "Every table and column added, changed or removed, with type, nullability, default and " \
                  "indexes. Changes must be additive first (expand, dual write, backfill, switch reads, " \
                  "then contract). Removing or renaming a column needs `ignored_columns` in an earlier step." },
      { key: "application_changes", title: "Application changes", group: "Architectural changes", source: :draft,
        required: true, min_words: 40,
        guidance: "Models, services, controllers, policies, jobs and UI that change, one subsection each." },
      { key: "infrastructure_changes", title: "Infrastructure changes", group: "Architectural changes",
        source: :draft, required: true, min_words: 5,
        guidance: "Queues, external services, feature flags and rollout order. Say so when there are none." },
      { key: "out_of_scope", title: "Out of Scope", group: "Work overview", source: :ask, required: false,
        min_words: 0, question: "What is explicitly out of scope?",
        guidance: "What this plan deliberately doesn't do." },
      { key: "risks", title: "Risks", group: "Risks", source: :draft, required: true, min_words: 15,
        guidance: "The main risks as a list, and how each is mitigated." },
      { key: "performance", title: "Performance", group: "Risks", source: :draft, required: true, min_words: 10,
        guidance: "Query counts, N+1 risks, indexes, large tables, batch sizes for backfills." },
      { key: "security", title: "Security", group: "Risks", source: :draft, required: true, min_words: 10,
        guidance: "Authorization, data exposure and input validation. End with a line `Risk Level: LOW`, " \
                  "`MEDIUM` or `HIGH` and one sentence why." },
      { key: "monitoring", title: "Monitoring", group: "Risks", source: :draft, required: false, min_words: 0,
        guidance: "What to watch after release: errors, jobs, metrics." },
      { key: "outstanding_questions", title: "Outstanding questions", group: "Risks", source: :draft,
        required: false, min_words: 0,
        guidance: "Open questions that must be answered before a phase ships. Don't invent answers." },
      { key: "testing", title: "Testing", group: "Testing", source: :draft, required: true, min_words: 20,
        guidance: "Model, service, policy, request and system coverage, as a list of the main cases, " \
                  "including legacy data and permissions." }
    ].freeze
  end
end
