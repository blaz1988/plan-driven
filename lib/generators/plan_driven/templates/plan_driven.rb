# frozen_string_literal: true

# Keys are never set here. They come from the environment or ~/.plan_driven/config,
# written by `bundle exec plan-driven configure`. The gem is usually in the :development group
# only, hence the check.
if defined?(PlanDriven.configure)
  PlanDriven.configure do |config|
    # The model that drafts plans and tickets. A stronger model is worth it here.
    # config.llm_provider = :openai          # or :anthropic, or :cursor (any model on your Cursor
    # config.llm_model = "gpt-4.1"           # account, e.g. "claude-opus-5-5"; reads your code)
    # config.request_timeout = 180           # seconds; a large model can need 600 for a full plan

    # Who must approve before the next phase starts.
    # config.plan_approvals = %w[review qa devops director]
    # config.ticket_approvals = %w[review]

    # Coding agents: one agent and one pull request per ticket. Cursor cloud agents by default,
    # or a local CLI in its own git worktree per ticket.
    # config.agent_model = "composer-2.5"
    # config.agent_provider = :local
    # config.agent_command = "claude -p --permission-mode acceptEdits --output-format json"
    # config.base_branch = "main"
    # config.max_parallel_agents = 3

    # Dollars per million tokens, for the cost in `plan-driven usage` and the delivery report.
    # config.token_prices = { "your-model-id" => { input: 3.0, output: 15.0, cache_read: 0.3 } }

    # GitHub. The repository is read from `git remote get-url origin` when not set.
    # config.github_repository = "your-org/your-app"
    # config.sync_issues = true
    # config.merge_method = "squash"

    # Guards.
    # config.estimate_scale = [1, 2, 3, 5, 8]
    # config.max_estimate = 5
    # config.max_pr_changed_lines = 800
    # config.cucumber = true

    # Your team's conventions, added to every agent prompt.
    # config.team_rules = [
    #   "Service objects live in app/services and respond to .call.",
    #   "Authorization goes through Pundit policies, never in controllers."
    # ]

    # The browser wizard at /plan_driven: development only by default, local requests always.
    # config.wizard_enabled = true
  end
end
