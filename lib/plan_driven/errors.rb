# frozen_string_literal: true

module PlanDriven
  class Error < StandardError; end
  class ConfigurationError < Error; end
  class ProviderError < Error; end
  class InvalidResponseError < Error; end

  # A phase transition that the workflow doesn't allow, such as generating tickets for a plan
  # nobody has approved.
  class TransitionError < Error; end

  # A guard found problems that block the next step. `problems` holds the messages.
  class GuardError < Error
    attr_reader :problems

    def initialize(problems, message = nil)
      @problems = Array(problems)
      super(message || "#{@problems.size} problem(s) block this step:\n#{@problems.map { |p| "  - #{p}" }.join("\n")}")
    end
  end
end
