# frozen_string_literal: true

module PlanDriven
  module Guards
    # Checks a drafted plan against the template and against the application it describes.
    class PlanGuard
      PLACEHOLDER = /\b(TBD|TODO|lorem ipsum|FIXME|XXX)\b/i
      RISK_LEVEL = /risk level\W{0,5}(LOW|MEDIUM|HIGH)\b/i
      MODEL_PATH = %r{\bapp/models/[\w/]+\.rb\b}
      CONSTANT = /`((?:[A-Z][a-z0-9]+)+(?:::(?:[A-Z][a-z0-9]+)+)*)`/
      TABLE_COLUMN = /`([a-z][a-z0-9_]*)\.([a-z][a-z0-9_]*)`/

      def initialize(sections, schema:, template: PlanDriven.configuration.template)
        @sections = (sections || {}).transform_keys(&:to_s)
        @schema = schema
        @template = template
      end

      def call
        report = Report.new
        check_sections(report)
        check_risk_level(report)
        check_existing_structure(report)
        report.merge!(MigrationGuard.new(@sections["database_changes"].to_s, schema: @schema).call)
        report
      end

      private

      def check_sections(report)
        @template.sections.each do |section|
          text = @sections[section.key].to_s.strip
          if section.required && text.empty?
            report.error("#{section.title} is empty")
          elsif section.required && words(text) < section.min_words.to_i
            report.error("#{section.title} is too thin (#{words(text)} words, at least #{section.min_words})")
          end
          if text.match?(PLACEHOLDER)
            report.warning("#{section.title} still contains a placeholder (#{text[PLACEHOLDER]})")
          end
        end
      end

      def check_risk_level(report)
        return if @sections["security"].to_s.match?(RISK_LEVEL)

        report.error("Security doesn't state a risk level (a line like `Risk Level: MEDIUM`)")
      end

      # The one place a plan must match the code exactly: what it calls existing has to exist.
      def check_existing_structure(report)
        text = @sections["existing_data_structure"].to_s
        text.scan(MODEL_PATH).uniq.each do |path|
          report.error("Existing Data Structure cites #{path}, which isn't in the app") unless root.join(path).exist?
        end
        text.scan(CONSTANT).flatten.uniq.each do |name|
          next if @schema.model?(name) || known_constant?(name)

          report.error("Existing Data Structure describes `#{name}` as existing, but there's no such model")
        end
        text.scan(TABLE_COLUMN).uniq.each do |table, column|
          next unless @schema.table?(table)
          next if @schema.column?(table, column)

          report.error("Existing Data Structure mentions `#{table}.#{column}`, but #{table} has no #{column} column")
        end
      end

      def known_constant?(name)
        Object.const_defined?(name)
      rescue NameError
        false
      end

      def root
        PlanDriven.configuration.root_path
      end

      def words(text)
        text.split(/\s+/).count { |word| word.match?(/\w/) }
      end
    end
  end
end
