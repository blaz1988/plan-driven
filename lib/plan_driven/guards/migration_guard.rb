# frozen_string_literal: true

module PlanDriven
  module Guards
    # Zero-downtime rules for the Database changes section: expand first, contract last.
    class MigrationGuard
      # Removing a constraint, an index or a foreign key loses no data, so `remove_check_constraint`
      # is not a removal; the migration methods that drop columns are listed by name.
      DESTRUCTIVE = /
        \b(remov(e|es|ed|ing|al)|drop(s|ped|ping)?|delet(e|es|ed|ing|ion)|renam(e|es|ed|ing))\b
          [^.\n]{0,80}\b(column|table|field)s?\b
        | \b(remove_columns?|remove_reference|remove_belongs_to|remove_timestamps|drop_table|
             rename_column|rename_table|change_column)\b
      /ix
      # A removal is staged when its own sentence says so, or when it sits under a contract step.
      SAFE_REMOVAL = Regexp.union(/ignored_columns|\bcontract\b/i, /in a later (step|phase|release|migration|deploy)/i,
                                  /after (the )?(backfill|deploy)|once (reads|the code|no code)/i)
      LATER_STEP = /\b(contract|clean[\s-]?up|later (step|phase|release|migration|deploy)|follow[\s-]?up)\b/i
      ROLLBACK = /\b(roll[\s-]?back|down migration|undo)\b/i
      NEGATED = /\b(no|not|never|none|nothing|don't|doesn't|won't|without|isn't|aren't)\b/i
      UNCHANGED = /\b(not\s(be\s)?(changed|modified|touched)|unchanged|untouched|no\schanges?\b|
                     keeps?\s(its|their)\s(current|existing)|stays?\sthe\ssame|as\s(it|they)\s(is|are)\stoday)/ix
      NOT_NULL = /\bnot[\s_-]?null\b|null:\s*false/i
      NOT_NULL_SAFE = /default|backfill|nullable first|after (the )?backfill|validate/i
      INDEX = /\badd_index\b|\bindex(es)?\b/i
      CONCURRENT = /concurrent|algorithm:\s*:concurrently|disable_ddl_transaction/i
      NEW_TABLE = /
        create_table\s+[:"']?([a-z][a-z0-9_]+)
        | new\s+table(?::\s*`?|\s+`)([a-z][a-z0-9_]+)
        | create\s+(?:a\s+|the\s+)?(?:new\s+)?`([a-z][a-z0-9_]+)`\s+table
        | create\s+(?:a\s+|the\s+)?(?:new\s+)?table\s+`?([a-z][a-z0-9_]+)
        | create:?\s+`([a-z][a-z0-9_]+)`(?!\s+(?:column|index))
        | _create_([a-z][a-z0-9_]+)\.rb
      /ix

      def initialize(text, schema:)
        @text = text.to_s
        @schema = schema
      end

      def call
        report = Report.new
        return report if @text.strip.empty?

        check_destructive(report)
        check_not_null(report)
        check_indexes(report)
        report
      end

      # Tables the section creates. One that's already in the schema isn't new, however it's
      # mentioned (a plan citing `20260929_create_rsvps.rb` as an example creates nothing).
      def new_tables
        @text.scan(NEW_TABLE).flatten.compact.map(&:downcase).uniq - @schema.tables
      end

      private

      def check_destructive(report)
        created = new_tables
        unsafe = destructive_statements.reject do |statement, heading|
          statement.match?(SAFE_REMOVAL) || statement.match?(ROLLBACK) ||
            heading.to_s.match?(LATER_STEP) || heading.to_s.match?(ROLLBACK) ||
            only_new_tables?(statement, created)
        end
        return if unsafe.empty?

        report.error("Database changes remove or rename a column or table in one step " \
                     "(\"#{unsafe.first.first.strip[0, 90]}\"). Split it: stop using it and add it to " \
                     "`ignored_columns`, deploy, then remove it in a later contract step.")
      end

      # [sentence or code line, the heading it's under] for every change that removes or renames.
      # Headings are only context ("### Removed or renamed columns"), and a negated sentence
      # ("No column is removed") changes nothing.
      def destructive_statements
        statements.select do |statement, _heading, fenced|
          statement.match?(DESTRUCTIVE) && (fenced || !negated?(statement))
        end
      end

      public

      # Existing tables the section changes: something is added to them or removed from them.
      # Tables it only compares with ("same as `rsvps`") or names as staying the same
      # ("### Tables not changed") don't count.
      def changed_tables
        removals = destructive_statements.reject { |statement, heading| unchanged?(statement, heading) }
        @schema.tables.select do |table|
          named = /\b#{Regexp.escape(table)}\b/
          paragraph_changing(table).split("\n").any? { |line| !line.match?(UNCHANGED) } ||
            removals.any? { |statement, _| statement.match?(named) }
        end
      end

      private

      def unchanged?(statement, heading)
        statement.match?(UNCHANGED) || heading.to_s.match?(UNCHANGED)
      end

      # [sentence or code line, the heading above it, inside a code block?] for the whole section.
      def statements
        heading = nil
        fenced = false
        @text.each_line.with_object([]) do |line, found|
          if line.start_with?("```")
            fenced = !fenced
          elsif !fenced && line.match?(/\A\#{1,6}\s/)
            heading = line
          else
            (fenced ? [line] : line.split(/(?<=[.!?])\s+/)).each { |statement| found << [statement, heading, fenced] }
          end
        end
      end

      # Dropping or changing a table this plan creates touches nothing that runs today.
      def only_new_tables?(statement, created)
        named = statement.scan(/[:`"']([a-z][a-z0-9_]*)\b/).flatten & @schema.tables
        created.any? && named.empty? && created.any? { |table| statement.match?(/\b#{Regexp.escape(table)}\b/) }
      end

      # Only a negation before the change counts: "No column is removed", not "Drop it; no code reads it".
      def negated?(statement)
        change = statement =~ /\b(remove|drop|delete|rename|change_column)/i
        change && statement[0, change].match?(NEGATED)
      end

      def check_not_null(report)
        existing_tables_mentioned.each do |table|
          paragraph = paragraph_changing(table)
          next unless paragraph.match?(NOT_NULL) && !paragraph.match?(NOT_NULL_SAFE)

          report.warning("A NOT NULL change on existing table #{table} has no default or backfill step; " \
                         "it will fail on existing rows")
        end
      end

      def check_indexes(report)
        adapter = @schema.respond_to?(:adapter) ? @schema.adapter : nil
        return unless adapter.to_s.match?(/postg/i)

        existing_tables_mentioned.each do |table|
          paragraph = paragraph_changing(table)
          next unless paragraph.match?(INDEX) && !paragraph.match?(CONCURRENT)

          report.warning("An index on existing table #{table} isn't built concurrently; it locks writes while " \
                         "it builds")
        end
      end

      def existing_tables_mentioned
        @schema.tables.select { |table| @text.match?(/\b#{Regexp.escape(table)}\b/) } - new_tables
      end

      # Paragraphs that change an existing table, not ones that only describe it (plans list the
      # current schema, "user_id integer, not null", before saying what changes).
      def paragraph_changing(table)
        name = Regexp.escape(table)
        change = /
          \b(add_column|change_column_null|change_column_default|add_reference|add_belongs_to|add_index|
             change_table|add_check_constraint)\s*\(?\s*[:"']#{name}\b
          | \b(add|adds|adding)\b[^.\n]{0,80}\b(to|on)\s+(the\s+)?`?#{name}`?
          | `?#{name}`?\s+(table\s+)?(gets|gains)\b
          | \A\#+\s+`?#{name}`?\s*\n[^\n]*\b(add\w*|change\w*|makes?)\b
        /ix
        @text.split(/\n\s*\n|\n(?=#+ )/).grep(change).join("\n")
      end
    end
  end
end
