# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `llm_provider :cursor` drafts plans and tickets with a model on the user's Cursor account
  (Claude Opus 5.5 by default) through the Cursor SDK. The agent reads the application's code
  with read-only tools.
- `doctor` checks the agent model against the models the Cursor key can use, and Node and the
  SDK for `:cursor`.
- `status` suggests the next step during development.

### Fixed

- `merge` marks an agent's draft pull request ready for review before merging it.
- The delivery report shows the Cucumber command without its temporary output path.

## [0.1.0] - 2026-09-29

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
  criteria, estimate, dependencies and the tables they touch.
- `approve-tickets` approves them and creates a GitHub issue for each.

### Development

- `develop` starts one Cursor cloud agent per ready ticket, within `max_parallel_agents`. A
  ticket is ready once every ticket it depends on is merged.
- `status` follows agents to their pull requests and notices pull requests merged on GitHub.
- `review`, `approve-pr`, `feedback` (a follow-up to the same agent) and `merge`, which needs
  the ticket key typed and waits for CI.

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
  acceptance criterion, and CI results.
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
- Keys from the environment, then `~/.plan_driven/config` (mode 0600), written by
  `plan-driven configure`; the GitHub token can also come from `gh auth token`.
- `plan-driven doctor` checks keys, the repository, the PDF browser and the Cursor API.

[Unreleased]: https://github.com/blaz1988/plan-driven/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/blaz1988/plan-driven/releases/tag/v0.1.0
