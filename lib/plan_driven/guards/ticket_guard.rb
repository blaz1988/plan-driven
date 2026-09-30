# frozen_string_literal: true

module PlanDriven
  module Guards
    # Checks the ticket breakdown: every ticket is small, testable and ordered so that each
    # pull request can merge on its own without breaking the application.
    class TicketGuard
      BUILDS_ON_MIGRATION = %w[dual_write backfill code switch cleanup].freeze
      MAX_CRITERIA = 8
      LAYER_TITLE = /\A(models?|services?|controllers?|views?|polic(y|ies)|ui|api|routes?|specs?|tests?)\s*:/i

      def initialize(tickets, plan_sections:, schema:, config: PlanDriven.configuration)
        @tickets = tickets
        @sections = (plan_sections || {}).transform_keys(&:to_s)
        @schema = schema
        @config = config
      end

      def call
        report = Report.new
        if @tickets.empty?
          report.error("There are no tickets")
          return report
        end

        @tickets.each { |ticket| check_ticket(ticket, report) }
        check_slicing(report)
        check_dependencies(report)
        check_order(report) if report.ok?
        check_coverage(report)
        report
      end

      private

      # A model ticket, then a controller ticket, then a view ticket: none of them does anything
      # a user can see, so no scenario can prove its criteria.
      def check_slicing(report)
        layered = @tickets.select { |ticket| ticket["kind"] == "code" && ticket["title"].to_s.match?(LAYER_TITLE) }
        return if layered.size < 2

        report.error("#{layered.map { |t| t["key"] }.join(", ")} split the work by layer (model, service, " \
                     "controller, view). Split code tickets by behaviour instead: each one delivers one thing a " \
                     "user can do, with its model, service, controller, view and specs together")
      end

      def check_ticket(ticket, report)
        label = ticket["key"]
        report.error("#{label} has no title") if ticket["title"].to_s.strip.empty?
        report.warning("#{label}: title is longer than 100 characters") if ticket["title"].to_s.length > 100
        report.error("#{label} has an unknown type #{ticket["type"]}") unless Ticket::TYPES.include?(ticket["type"])
        report.error("#{label} has no description") if ticket["description"].to_s.strip.empty?
        if ticket["type"] == "STORY" && ticket["story"].to_s !~ /\bso that\b/i
          report.error("#{label} is a story without \"so that\"")
        end
        check_criteria(ticket, label, report)
        check_estimate(ticket, label, report)
      end

      def check_criteria(ticket, label, report)
        criteria = ticket["acceptance_criteria"]
        report.error("#{label} has no acceptance criteria") if criteria.empty?
        criteria.each_with_index do |criterion, index|
          next if criterion.split.size >= 3

          report.error("#{label} acceptance criterion #{index + 1} is too short to test: \"#{criterion}\"")
        end
        return unless criteria.size > MAX_CRITERIA

        report.warning("#{label} has #{criteria.size} acceptance criteria; consider splitting it")
      end

      def check_estimate(ticket, label, report)
        estimate = ticket["estimate"]
        if estimate.nil?
          report.error("#{label} has no estimate")
        elsif estimate > @config.max_estimate
          report.error("#{label} is estimated at #{estimate}, above the limit of #{@config.max_estimate}; split it")
        end
      end

      def check_dependencies(report)
        keys = @tickets.map { |ticket| ticket["key"] }
        @tickets.each do |ticket|
          (ticket["depends_on"] - keys).each do |missing|
            report.error("#{ticket["key"]} depends on unknown #{missing}")
          end
          report.error("#{ticket["key"]} depends on itself") if ticket["depends_on"].include?(ticket["key"])
        end
        cycle = find_cycle
        report.error("Dependencies form a cycle: #{cycle.join(" -> ")}") if cycle
      end

      # Expand before contract, per table: anything using a table must build on the migration
      # that changes it, and removing things comes after every backfill and read switch.
      def check_order(report)
        @tickets.each do |ticket|
          ancestors = ancestors_of(ticket["key"])
          ticket["touches"].each do |table|
            required_before(ticket, table).each do |earlier|
              next if ancestors.include?(earlier["key"])

              report.error("#{ticket["key"]} (#{phase(ticket)}) touches #{table} but doesn't depend on " \
                           "#{earlier["key"]} (#{phase(earlier)}), which must merge first")
            end
          end
        end
      end

      def required_before(ticket, table)
        others = @tickets.reject { |other| other["key"] == ticket["key"] || !other["touches"].include?(table) }
        case phase(ticket)
        when "cleanup"
          others.select { |other| %w[migration dual_write backfill switch].include?(phase(other)) }
        when *BUILDS_ON_MIGRATION then others.select { |other| phase(other) == "migration" }
        else []
        end
      end

      # A migration that removes or renames something is the contract step, whatever it's called.
      def phase(ticket)
        return ticket["kind"] unless ticket["kind"] == "migration"

        text = "#{ticket["title"]}\n#{ticket["description"]}"
        text.match?(MigrationGuard::DESTRUCTIVE) ? "cleanup" : "migration"
      end

      def check_coverage(report)
        touched = @tickets.flat_map { |ticket| ticket["touches"] }.uniq
        planned = MigrationGuard.new(@sections["database_changes"].to_s, schema: @schema)
        new_tables = planned.new_tables
        (new_tables + planned.changed_tables).uniq.each do |table|
          next if touched.include?(table)

          report.warning("Database changes mention #{table}, but no ticket touches it")
        end
        (touched - @schema.tables - new_tables).each do |table|
          report.warning("A ticket touches #{table}, which isn't in the schema or the plan's database changes")
        end
      end

      def ancestors_of(key, seen = Set.new)
        ticket = @tickets.find { |candidate| candidate["key"] == key }
        Array(ticket && ticket["depends_on"]).each do |dependency|
          next if seen.include?(dependency)

          seen << dependency
          ancestors_of(dependency, seen)
        end
        seen
      end

      def find_cycle
        state = {}
        @tickets.each do |ticket|
          path = visit(ticket["key"], state, [])
          return path if path
        end
        nil
      end

      def visit(key, state, path)
        return path + [key] if state[key] == :visiting
        return if state[key] == :done

        state[key] = :visiting
        ticket = @tickets.find { |candidate| candidate["key"] == key }
        Array(ticket && ticket["depends_on"]).each do |dependency|
          found = visit(dependency, state, path + [key])
          return found.drop_while { |step| step != found.last } if found
        end
        state[key] = :done
        nil
      end
    end
  end
end
