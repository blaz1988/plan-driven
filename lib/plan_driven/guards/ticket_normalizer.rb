# frozen_string_literal: true

module PlanDriven
  module Guards
    # Deterministic fixes applied to drafted tickets before they're checked. Anything that has
    # exactly one right answer is corrected here and reported, instead of being sent back to the
    # model for another attempt.
    class TicketNormalizer
      TITLE_PREFIX = { "migration" => "Migration: ", "backfill" => "Data migration: " }.freeze
      KIND_ALIASES = {
        "schema" => "migration", "db" => "migration", "database" => "migration",
        "data_migration" => "backfill", "data" => "backfill", "feature" => "code", "application" => "code",
        "read_switch" => "switch", "contract" => "cleanup", "removal" => "cleanup", "documentation" => "docs"
      }.freeze

      def initialize(tickets, config: PlanDriven.configuration)
        @tickets = Array(tickets).map { |ticket| ticket.to_h.transform_keys(&:to_s) }
        @config = config
      end

      def call(report)
        keys = {}
        tickets = @tickets.each_with_index.map { |ticket, index| normalize(ticket, index, keys, report) }
        remap_dependencies(tickets, keys)
        tickets
      end

      private

      def normalize(ticket, index, keys, report)
        key = "T#{index + 1}"
        keys[ticket["key"].to_s] = key unless ticket["key"].to_s.empty?
        ticket.merge!("key" => key, "position" => index)
        ticket["kind"] = kind(ticket["kind"], key, report)
        ticket["type"] = ticket["type"].to_s.upcase.presence || "TASK"
        ticket["title"] = title(ticket["title"].to_s.strip, ticket["kind"], key, report)
        ticket["estimate"] = estimate(ticket["estimate"], key, report)
        normalize_lists(ticket)
      end

      def normalize_lists(ticket)
        ticket["acceptance_criteria"] = list(ticket["acceptance_criteria"])
        ticket["depends_on"] = list(ticket["depends_on"]).map(&:upcase)
        ticket["touches"] = list(ticket["touches"]).map { |table| table.downcase.delete("`") }
        ticket
      end

      def kind(value, label, report)
        value = value.to_s.downcase.strip.tr(" -", "__")
        return value if Ticket::KINDS.include?(value)

        mapped = KIND_ALIASES[value] || "code"
        report.fix("#{label}: kind \"#{value}\" read as #{mapped}") unless value.empty?
        mapped
      end

      def title(value, kind, label, report)
        prefix = TITLE_PREFIX[kind]
        return value if prefix.nil? || value.start_with?(prefix)

        stripped = value.sub(/\A(data\s+)?migration:\s*/i, "")
        report.fix("#{label}: title prefixed with \"#{prefix.strip}\"")
        "#{prefix}#{stripped}"
      end

      def estimate(value, label, report)
        number = value.to_s[/\d+/]&.to_i
        return if number.nil?

        scale = @config.estimate_scale
        return number if scale.include?(number)

        rounded = scale.find { |point| point >= number } || scale.last
        report.fix("#{label}: estimate #{number} rounded up to #{rounded}, the next point on the scale")
        rounded
      end

      def list(value)
        items = value.is_a?(Array) ? value : value.to_s.split(/\n|;/)
        items.map { |item| item.to_s.strip.sub(/\A[-*\u2022]\s*/, "") }.reject(&:empty?)
      end

      def remap_dependencies(tickets, keys)
        tickets.each do |ticket|
          ticket["depends_on"] = ticket["depends_on"].map { |key| keys.fetch(key, key) }.uniq
        end
      end
    end
  end
end
