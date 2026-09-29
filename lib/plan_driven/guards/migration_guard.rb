# frozen_string_literal: true

module PlanDriven
  module Guards
    # Zero-downtime rules for the Database changes section: expand first, contract last.
    class MigrationGuard
      DESTRUCTIVE = /\b(remove|drop|delete|rename)\w*\b[^.\n]{0,80}\b(column|table|field)s?\b|
                     \b(remove_column|drop_table|rename_column|rename_table|change_column)\b/ix
      SAFE_REMOVAL = /ignored_columns|expand|contract|in a later (step|phase|release)|after (the )?backfill/i
      NOT_NULL = /\bnot[\s_-]?null\b|null:\s*false/i
      NOT_NULL_SAFE = /default|backfill|nullable first|after (the )?backfill|validate/i
      INDEX = /\badd_index\b|\bindex(es)?\b/i
      CONCURRENT = /concurrent|algorithm:\s*:concurrently|disable_ddl_transaction/i
      NEW_TABLE = /
        create_table\s+[:"']?([a-z][a-z0-9_]+)
        | new\s+table:?\s*`?([a-z][a-z0-9_]+)
        | create\s+(?:a\s+|the\s+)?(?:new\s+)?`([a-z][a-z0-9_]+)`\s+table
        | create\s+(?:a\s+|the\s+)?(?:new\s+)?table\s+`?([a-z][a-z0-9_]+)
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

      def new_tables
        @text.scan(NEW_TABLE).flatten.compact.map(&:downcase).uniq
      end

      private

      def check_destructive(report)
        return unless @text.match?(DESTRUCTIVE)
        return if @text.match?(SAFE_REMOVAL)

        report.error("Database changes remove or rename a column or table in one step. Split it: stop using " \
                     "it and add it to `ignored_columns`, deploy, then remove it in a later migration.")
      end

      def check_not_null(report)
        existing_tables_mentioned.each do |table|
          paragraph = paragraph_about(table)
          next unless paragraph.match?(NOT_NULL) && !paragraph.match?(NOT_NULL_SAFE)

          report.warning("A NOT NULL change on existing table #{table} has no default or backfill step; " \
                         "it will fail on existing rows")
        end
      end

      def check_indexes(report)
        adapter = @schema.respond_to?(:adapter) ? @schema.adapter : nil
        return unless adapter.to_s.match?(/postg/i)

        existing_tables_mentioned.each do |table|
          paragraph = paragraph_about(table)
          next unless paragraph.match?(INDEX) && !paragraph.match?(CONCURRENT)

          report.warning("An index on existing table #{table} isn't built concurrently; it locks writes while " \
                         "it builds")
        end
      end

      def existing_tables_mentioned
        @schema.tables.select { |table| @text.match?(/\b#{Regexp.escape(table)}\b/) } - new_tables
      end

      def paragraph_about(table)
        @text.split(/\n\s*\n|\n(?=#+ )/).grep(/\b#{Regexp.escape(table)}\b/).join("\n")
      end
    end
  end
end
