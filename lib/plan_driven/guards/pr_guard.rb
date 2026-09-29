# frozen_string_literal: true

module PlanDriven
  module Guards
    # Checks the pull request an agent opened against the ticket it was given. Runs before a human
    # is asked to approve it, and again before merge.
    class PrGuard
      MIGRATION_PATHS = %r{\Adb/}
      CHECK_OK = %w[success neutral skipped].freeze

      def initialize(ticket, pull:, files:, checks:, features: {}, behind: 0, config: PlanDriven.configuration)
        @ticket = ticket
        @pull = pull || {}
        @files = files
        @checks = checks
        @features = features
        @behind = behind
        @config = config
      end

      def call
        report = Report.new
        check_reference(report)
        check_size(report)
        check_specs(report)
        check_migrations(report)
        check_acceptance_scenarios(report) if @config.cucumber && @ticket.kind != "docs"
        check_ci(report)
        check_base(report)
        report
      end

      private

      def paths
        @paths ||= @files.map { |file| file["filename"] }
      end

      def check_reference(report)
        text = "#{@pull["title"]}\n#{@pull["body"]}"
        report.warning("The PR doesn't mention #{@ticket.reference}") unless text.include?(@ticket.reference)
        number = @ticket.issue_number
        if number && !text.match?(/(close[sd]?|fix(e[sd])?|resolve[sd]?) ##{number}\b/i)
          report.warning("The PR doesn't close issue ##{number}")
        elsif text.include?(@ticket.reference)
          report.pass(["Refers to #{@ticket.reference}", ("closes ##{number}" if number)].compact.join(" and "))
        end
      end

      def check_size(report)
        changed = @files.sum { |file| file["additions"].to_i + file["deletions"].to_i }
        limit = @config.max_pr_changed_lines
        return report.pass("#{@files.size} files, #{changed} changed lines (limit #{limit})") if changed <= limit

        report.error("The PR changes #{changed} lines, above the limit of #{limit}")
      end

      def check_specs(report)
        return unless @config.require_specs_in_pr
        return if @ticket.kind == "docs"

        specs = paths.count { |path| spec_path?(path) }
        return report.pass("#{specs} spec and feature files changed") if specs.positive?

        report.error("The PR has no spec or feature changes")
      end

      def check_migrations(report)
        added = @files.select { |file| file["filename"].start_with?("db/migrate/") && file["status"] == "added" }
        if added.any? && !%w[migration backfill].include?(@ticket.kind)
          report.error("A #{@ticket.kind} ticket adds a migration (#{added.first["filename"]}); " \
                       "schema changes belong in their own migration ticket")
        end
        check_migration_scope(report)
        if added.empty? && @ticket.kind != "migration"
          report.pass("No migrations, so the schema stays with the migration tickets")
        end
        return if added.empty? || paths.any? { |path| path.match?(%r{\Adb/(schema\.rb|structure\.sql)\z}) }

        report.warning("A migration was added but db/schema.rb didn't change")
      end

      def check_migration_scope(report)
        return unless @ticket.kind == "migration"

        app_changes = paths.reject { |path| path.match?(MIGRATION_PATHS) || spec_path?(path) }
        return report.pass("A migration ticket, and it only changes db/ and tests") if app_changes.empty?

        report.warning("A migration ticket also changes #{app_changes.first(3).join(", ")}")
      end

      def check_acceptance_scenarios(report)
        tagged = @features.flat_map do |path, text|
          Gherkin.parse(text, path: path).scenarios.select { |scenario| scenario.tags.include?(@ticket.feature_tag) }
        end
        if tagged.empty?
          report.error("No Cucumber scenario is tagged #{@ticket.feature_tag}")
          return
        end
        @ticket.criteria.each_index do |index|
          tag = "@ac-#{index + 1}"
          next if tagged.any? { |scenario| scenario.tags.include?(tag) }

          report.error("Acceptance criterion #{index + 1} has no scenario tagged #{@ticket.feature_tag} #{tag}")
        end
        count = @ticket.criteria.size
        return unless report.errors.none? { |message| message.start_with?("Acceptance criterion") }

        report.pass("All #{count} acceptance criteria have a scenario tagged #{@ticket.feature_tag} @ac-N")
      end

      def check_ci(report)
        if @checks.empty?
          report.warning("No CI checks have reported on this PR yet")
          return
        end
        pending = @checks.reject { |check| check["status"] == "completed" }
        failed = @checks.select { |check| check["status"] == "completed" && !CHECK_OK.include?(check["conclusion"]) }
        failed.each { |check| report.error("CI check \"#{check["name"]}\" #{check["conclusion"]}") }
        report.warning("#{pending.size} CI check(s) still running") if pending.any?
        return unless pending.empty? && failed.empty?

        report.pass("CI is green: #{@checks.map { |check| check["name"] }.join(", ")}")
      end

      # Another ticket merged since the agent branched: CI passed without those changes.
      def check_base(report)
        base = @pull.dig("base", "ref") || "the base branch"
        return report.pass("Up to date with #{base}") if @behind.zero?

        report.warning("The branch is #{@behind} commit(s) behind #{base}, so CI ran without them. " \
                       "Ask the agent to merge #{base} and run the checks again (`plan-driven feedback`).")
      end

      def spec_path?(path)
        @config.spec_paths.any? { |prefix| path.start_with?(prefix) }
      end
    end
  end
end
