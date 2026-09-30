# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The browser wizard: a Rails engine the install generator mounts at `/plan_driven`, in
  development only. It walks a plan through the interview, plan, approval, tickets, agents
  and evidence with Back and Next, and every button runs the matching `plan-driven` command in
  the background, with the command and its live output shown beside the form. Only a fixed
  list of commands can run, for local requests only (`config.wizard_enabled`).
- `plan-driven edit PLAN SECTION --from FILE` replaces a section with a file's contents.
- Tokens and cost. Every model call (drafting, redrafts, tickets) and every agent run is
  recorded with its tokens and duration. `plan-driven usage PLAN` prints them, and the delivery
  report has a Tokens and cost table. `config.token_prices` turns tokens into dollars.
- Local coding agents: `config.agent_provider = :local` runs `config.agent_command` (Claude
  Code, Codex, the Cursor CLI...) in its own git worktree per ticket, then commits, pushes and
  opens the pull request. Feedback runs in the same worktree; the worktree is removed after
  the merge. `{prompt_file}` in the command passes the prompt as a file instead of stdin.
- `GitHub#create_pull`, and Cursor agent runs carry `duration_ms`.

### Changed

- MigrationGuard judges each removal or rename on its own sentence, or migration code line,
  and the step it sits under. Before, the word "expand" or "contract" anywhere in Database
  changes excused every destructive change in the section. Headings, negated sentences,
  rollback notes and tables the plan creates are no longer read as removals.
- Terminal tables fit the terminal width, cutting the last column short instead of wrapping.
- When answers are piped into `plan-driven new`, the interview prints each answer after its
  question, so the transcript reads like the terminal session.

### Fixed

- `evidence` always runs Cucumber with `RAILS_ENV=test`. Started from a development server,
  as the wizard does, it inherited `RAILS_ENV=development` and ran the scenarios against the
  development database. The wizard also no longer passes the server's `RAILS_ENV` to commands.
- `remove_check_constraint` and other `remove_*` methods that drop no data are no longer
  destructive changes; `remove_column(s)`, `remove_reference`, `remove_timestamps`,
  `drop_table`, `rename_*` and `change_column` still are.
- Ticket coverage asks for tickets only for tables the plan creates or changes. Tables the
  plan names in prose, or that already exist in the schema, no longer need their own ticket.

## [0.1.0] - 2026-09-30

First public release.

### Plans

- `plan-driven new` interviews the team in the terminal (what, why, where, who, when,
  background, out of scope) and drafts the rest of the plan from the answers and the
  application's schema, following the usual Confluence implementation plan template.
- `edit` in `$EDITOR`, `redraft` with an instruction, `check`, `submit`, `approve` and
  `reject`. Approvals belong to a revision, so editing an approved plan asks for approval again.
- Plans are written to `docs/plans/<plan>/plan.{md,html,pdf}`, with the PDF rendered by
  headless Chrome or any configured renderer.

### Tickets

- `tickets` splits an approved plan into tickets with a type, kind, description, acceptance
  criteria, estimate, dependencies and the tables they touch. `tickets PLAN "instruction"`
  redrafts the whole set.
- `approve-tickets` approves them and creates a GitHub issue for each. Issue numbers and
  names in ticket text (`#1`, `@event`) don't turn into links or mentions.

### Development

- `develop` starts one Cursor cloud agent per ready ticket, within `max_parallel_agents`. A
  ticket is ready once every ticket it depends on is merged.
- `status` follows agents to their pull requests, notices pull requests merged on GitHub, and
  suggests the next step.
- `review` lists every check it ran, not only the failures. `approve-pr`, `feedback` (a
  follow-up to the same agent) and `merge`, which needs the ticket key typed, waits for CI and
  marks an agent's draft pull request ready before merging.

### Guards

- PlanGuard: required sections, minimum length, a security risk level, placeholders, and an
  Existing Data Structure section that cites only models, files and columns that exist.
- MigrationGuard: one-step removals and renames, NOT NULL without a default or backfill, and
  non-concurrent indexes on PostgreSQL.
- TicketNormalizer: keys, kinds, types, title prefixes and estimates corrected in code, and
  every correction reported.
- TicketGuard: acceptance criteria, estimates, dependency cycles, expand and contract order
  per table, and coverage of the plan's tables.
- PrGuard: size, specs, migrations only in migration tickets, a Cucumber scenario for every
  acceptance criterion, CI results, and a warning when the branch is behind the base branch.
- Guard errors go back to the model as a list to fix, up to `max_repair_attempts` times.

### Evidence

- `evidence` runs the plan's Cucumber scenarios, or imports a JSON run with `--from`, and maps
  each acceptance criterion to the scenarios tagged for it.
- `report` writes the delivery report: tickets and pull requests, the acceptance criteria
  proof matrix, guard findings, approvals and the timeline.
- `log` prints the append-only audit trail.

### Setup

- A `plan_driven:install` generator for the tables, the initializer and `docs/plans`.
- OpenAI and Anthropic over `net/http`, any OpenAI-compatible endpoint through `llm_api_base`.
- `llm_provider :cursor` drafts plans and tickets with a model on the user's Cursor account
  (Claude Opus 5.5 by default) through the Cursor SDK. The agent reads the application's code
  with read-only tools.
- Keys from the environment, then `~/.plan_driven/config` (mode 0600), written by
  `plan-driven configure`; the GitHub token can also come from `gh auth token`.
- `plan-driven doctor` checks keys, the repository, the PDF browser, the Cursor API, the agent
  model, and Node and the SDK for `:cursor`.

[Unreleased]: https://github.com/blaz1988/plan-driven/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/blaz1988/plan-driven/releases/tag/v0.1.0
