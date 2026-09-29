# frozen_string_literal: true

require "active_record"
require "active_support/core_ext/object/blank"
require "active_support/core_ext/string/inflections"
require "active_support/core_ext/string/filters"
require "pathname"
require "set"

require_relative "plan_driven/version"
require_relative "plan_driven/errors"
require_relative "plan_driven/credentials"
require_relative "plan_driven/configuration"
require_relative "plan_driven/template"
require_relative "plan_driven/schema_context"
require_relative "plan_driven/workflow"
require_relative "plan_driven/models"
require_relative "plan_driven/json_reply"
require_relative "plan_driven/llm"
require_relative "plan_driven/cursor_llm"
require_relative "plan_driven/guards"
require_relative "plan_driven/gherkin"
require_relative "plan_driven/drafter"
require_relative "plan_driven/ticket_generator"
require_relative "plan_driven/agent_prompt"
require_relative "plan_driven/http"
require_relative "plan_driven/github"
require_relative "plan_driven/cursor_agents"
require_relative "plan_driven/repository"
require_relative "plan_driven/renderer"
require_relative "plan_driven/evidence"
require_relative "plan_driven/delivery"
require_relative "plan_driven/railtie" if defined?(Rails::Railtie)

module PlanDriven
  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield configuration
    end

    def reset!
      @configuration = nil
    end

    # Names like "Blažević" arrive tagged with the locale's encoding, which under LANG=C is
    # binary, and binary strings can't be joined with the UTF-8 text of a plan.
    def actor
      name = ENV["PLAN_DRIVEN_ACTOR"].presence || git_identity || ENV.fetch("USER", "unknown")
      utf8(name)
    end

    def utf8(text)
      text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
    end

    private

    def git_identity
      name = utf8(`git config user.name 2>/dev/null`).strip
      email = utf8(`git config user.email 2>/dev/null`).strip
      return if name.empty? && email.empty?

      email.empty? ? name : "#{name} <#{email}>".strip
    rescue StandardError
      nil
    end
  end
end
