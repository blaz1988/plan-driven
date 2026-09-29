# frozen_string_literal: true

# Keys are never set here. They come from the environment or ~/.plan_driven/config,
# written by `bundle exec plan-driven configure`. The gem is usually in the :development group
# only, hence the check.
if defined?(PlanDriven.configure)
  PlanDriven.configure do |config|
    # The model that drafts plans and tickets. A stronger model is worth it here.
    # config.llm_provider = :openai          # or :anthropic, or :cursor (any model on your Cursor
    # config.llm_model = "gpt-4.1"           # account, e.g. "claude-opus-5-5"; reads your code)

    # Who must approve before the next phase starts.
    # config.plan_approvals = %w[review qa devops director]
    # config.ticket_approvals = %w[review]

    # Cursor cloud agents: one agent and one pull request per ticket.
    # config.agent_model = "composer-2.5"
    # config.base_branch = "main"
    # config.max_parallel_agents = 3

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
  end
end
