# frozen_string_literal: true

module PlanDriven
  # Rules enforced in Ruby rather than asked for in a prompt. A prompt line costs tokens on every
  # call and a model can ignore it; a guard runs every time and says exactly what's wrong.
  module Guards
    # Errors block the next phase. Warnings are shown and recorded, and a human decides.
    class Report
      attr_reader :errors, :warnings, :fixes

      def initialize
        @errors = []
        @warnings = []
        @fixes = []
      end

      def error(message) = errors << message
      def warning(message) = warnings << message
      def fix(message) = fixes << message

      def ok?
        errors.empty?
      end

      def merge!(other)
        errors.concat(other.errors)
        warnings.concat(other.warnings)
        fixes.concat(other.fixes)
        self
      end

      def to_h
        { "errors" => errors, "warnings" => warnings, "fixes" => fixes }
      end

      def self.from_h(hash)
        report = new
        hash ||= {}
        report.errors.concat(Array(hash["errors"]))
        report.warnings.concat(Array(hash["warnings"]))
        report.fixes.concat(Array(hash["fixes"]))
        report
      end
    end
  end
end

require_relative "guards/plan_guard"
require_relative "guards/migration_guard"
require_relative "guards/ticket_normalizer"
require_relative "guards/ticket_guard"
require_relative "guards/pr_guard"
