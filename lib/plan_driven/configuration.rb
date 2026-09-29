# frozen_string_literal: true

module PlanDriven
  # Everything has a default, so `plan-driven new` works in a fresh app with only keys set.
  #
  #     PlanDriven.configure do |config|
  #       config.llm_provider = :anthropic
  #       config.llm_model = "claude-sonnet-4-5"
  #       config.plan_approvals = %w[review qa devops director]
  #       config.cucumber = true
  #     end
  class Configuration
    DEFAULT_MODELS = { openai: "gpt-4.1", anthropic: "claude-sonnet-4-5", cursor: "claude-opus-5-5" }.freeze
    KEY_FOR_PROVIDER = { openai: :openai_api_key, anthropic: :anthropic_api_key, cursor: :cursor_api_key }.freeze

    # Planning and ticket writing are the steps where a stronger model pays for itself.
    attr_accessor :llm_provider, :llm_api_base, :temperature, :request_timeout, :max_repair_attempts
    attr_writer :llm_model

    # llm_provider :cursor runs the Cursor SDK under Node 22.13+.
    attr_accessor :node_command, :cursor_sdk_path

    # Who has to approve what before the next phase can start.
    attr_accessor :plan_approvals, :ticket_approvals

    # Where documentation is written, relative to the application root.
    attr_accessor :docs_path, :root

    # Cursor cloud agents.
    attr_accessor :agent_model, :base_branch, :max_parallel_agents, :skip_reviewer_request

    # GitHub.
    attr_accessor :github_repository, :sync_issues, :merge_method, :issue_labels

    # Guards.
    attr_accessor :estimate_scale, :max_estimate, :max_pr_changed_lines, :require_specs_in_pr,
                  :spec_paths, :cucumber, :features_path

    # Extra rules appended to every agent prompt: your team's conventions, in plain English.
    attr_accessor :team_rules

    # PDF rendering. A callable taking (html_path, pdf_path), or nil to use headless Chrome.
    attr_accessor :pdf_renderer

    # Anything the LLM should know that the schema doesn't show.
    attr_accessor :extra_context

    # The plan's sections. Template.default mirrors the usual Confluence implementation plan.
    attr_writer :template

    def template
      @template ||= Template.default
    end

    def initialize
      @llm_provider = :openai
      @llm_model = nil
      @llm_api_base = nil
      @temperature = 0.2
      @request_timeout = 180
      @max_repair_attempts = 2
      @node_command = ENV.fetch("PLAN_DRIVEN_NODE", "node")
      @cursor_sdk_path = nil

      @plan_approvals = %w[review]
      @ticket_approvals = %w[review]

      @docs_path = "docs/plans"
      @root = nil

      @agent_model = nil
      @base_branch = "main"
      @max_parallel_agents = 3
      @skip_reviewer_request = false

      @github_repository = nil
      @sync_issues = true
      @merge_method = "squash"
      @issue_labels = %w[plan-driven]

      @estimate_scale = [1, 2, 3, 5, 8]
      @max_estimate = 5
      @max_pr_changed_lines = 800
      @require_specs_in_pr = true
      @spec_paths = %w[spec/ test/ features/]
      @cucumber = true
      @features_path = "features"

      @team_rules = []
      @pdf_renderer = nil
      @extra_context = nil
    end

    def llm_model
      @llm_model || DEFAULT_MODELS.fetch(llm_provider.to_sym, DEFAULT_MODELS[:openai])
    end

    def llm_api_key
      Credentials.fetch(llm_key_name)
    end

    def llm_key_name
      KEY_FOR_PROVIDER.fetch(llm_provider.to_sym, :openai_api_key)
    end

    def root_path
      Pathname(root || (defined?(Rails) && Rails.respond_to?(:root) && Rails.root) || Dir.pwd)
    end

    def docs_root
      root_path.join(docs_path)
    end
  end
end
