# frozen_string_literal: true

require "fileutils"
require "yaml"

module PlanDriven
  # How the work is split into tickets and checked, as the team chose it with
  # `plan-driven setting` or the wizard's Configuration page. It lives in the application, in
  # config/plan_driven/settings.yml, so it is committed and the whole team works the same way:
  #
  #     settings:
  #       separate_migrations: false
  #       max_tickets: 4
  #
  # A value here wins over the initializer. Every default is the practice we recommend; each
  # option says what changing it gains and what it costs.
  module Settings
    PATH = "config/plan_driven/settings.yml"
    HEADER = "# plan_driven settings, as changed with `plan-driven setting` or the wizard.\n" \
             "# Commit it: everyone on the team splits and checks the work the same way.\n"
    ON = %w[true on yes 1].freeze
    OFF = %w[false off no 0].freeze
    NONE = %w[none no-limit unlimited].freeze

    Option = Struct.new(:key, :type, :choices, :minimum, :blank, :group, :title, :explanation, :tradeoff,
                        keyword_init: true)

    OPTIONS = [
      Option.new(
        key: "data_model_diagram", type: :boolean, group: "Plan",
        title: "Draw the data model the plan changes",
        explanation: "A diagram of the tables the plan creates, changes or removes, and the tables they " \
                     "reference, in the plan, its PDF and on GitHub. It's drawn from the migration code in " \
                     "Database changes and the real schema, not by the model, so the model is asked to write " \
                     "every schema change as migration code.",
        tradeoff: "Off: reviewers read the schema changes as text only. On costs no extra model call, only the " \
                  "few lines of migration code the plan should have anyway."
      ),
      Option.new(
        key: "ticket_split", type: :choice, choices: %w[small larger], group: "Tickets",
        title: "How finely the plan is split",
        explanation: "small: one thing a user can do per ticket, at most max_estimate points, so every pull " \
                     "request is small and quick to review. larger: related behaviours share a ticket, up to " \
                     "the top of the estimate scale.",
        tradeoff: "larger means fewer pull requests and agent runs, so fewer tokens, but each review is bigger " \
                  "and a problem in one part holds back the whole ticket."
      ),
      Option.new(
        key: "max_tickets", type: :integer, minimum: 1, blank: true, group: "Tickets",
        title: "At most this many tickets per plan",
        explanation: "Blank means no limit, and the plan decides. With a limit, the breakdown must fit in it, " \
                     "and a ticket above max_estimate is a warning instead of an error.",
        tradeoff: "A low limit gives fewer, larger pull requests and fewer agent runs; reviews get bigger."
      ),
      Option.new(
        key: "max_estimate", type: :integer, minimum: 1, group: "Tickets",
        title: "Largest ticket, in story points",
        explanation: "A ticket estimated above this must be split (with ticket_split small).",
        tradeoff: "Higher means fewer, bigger tickets."
      ),
      Option.new(
        key: "separate_migrations", type: :boolean, group: "Pull requests",
        title: "Schema changes in their own pull requests",
        explanation: "On: every schema change is a migration ticket of its own, merged and deployed before the " \
                     "code that uses it. That is the zero-downtime practice: each migration is reviewed on its " \
                     "own, and can be rolled out and rolled back separately. Off: an additive migration goes in " \
                     "the same pull request as the first code that needs it. Removing or renaming a column " \
                     "always keeps its own cleanup ticket.",
        tradeoff: "Off saves a pull request and an agent run for each migration, but the code and the schema " \
                  "change ship together, so a rollback undoes both."
      ),
      Option.new(
        key: "max_pr_changed_lines", type: :integer, minimum: 50, group: "Pull requests",
        title: "Largest pull request, in changed lines",
        explanation: "The pull request guard blocks a pull request that adds and removes more lines than this.",
        tradeoff: "Higher allows bigger tickets; past a few hundred lines, reviews get less careful."
      ),
      Option.new(
        key: "require_specs_in_pr", type: :boolean, group: "Quality",
        title: "Every pull request changes specs",
        explanation: "The pull request guard blocks a code pull request that doesn't add or change a spec or " \
                     "feature file.",
        tradeoff: "Off lets untested changes reach review; the reviewer has to catch them."
      ),
      Option.new(
        key: "cucumber", type: :boolean, group: "Quality",
        title: "Prove every acceptance criterion with a Cucumber scenario",
        explanation: "Each criterion needs a scenario tagged with it, the proof step runs them on the merged " \
                     "code, and the delivery report shows the result of every criterion.",
        tradeoff: "Off saves the agents writing scenarios, but nothing proves the criteria automatically and " \
                  "the delivery report has no proof."
      ),
      Option.new(
        key: "targeted_tests", type: :boolean, group: "Agents",
        title: "Agents run the specs they need while they work",
        explanation: "While working, an agent runs only the specs for the files it changes, then the whole suite " \
                     "once before it opens the pull request. CI and the guards still check everything.",
        tradeoff: "The biggest token saving: the output of every full-suite run stays in the agent's context. " \
                  "Off: agents run the whole suite as often as they like."
      ),
      Option.new(
        key: "max_parallel_agents", type: :integer, minimum: 1, group: "Agents",
        title: "Agents working at the same time",
        explanation: "How many tickets are handed to agents at once. Tickets still wait for the ones they " \
                     "depend on.",
        tradeoff: "More is faster, but more pull requests wait for review at the same time."
      )
    ].freeze

    module_function

    def keys
      OPTIONS.map(&:key)
    end

    def find(key)
      OPTIONS.find { |option| option.key == key.to_s } or
        raise ArgumentError, "Unknown setting #{key.inspect}. One of: #{keys.join(", ")}"
    end

    def path(root = PlanDriven.configuration.root_path)
      Pathname(root).join(PATH)
    end

    def read(root = PlanDriven.configuration.root_path)
      file = path(root)
      return {} unless file.exist?

      data = YAML.safe_load(file.read) || {}
      values = data.is_a?(Hash) ? data["settings"] : nil
      return {} unless values.is_a?(Hash)

      values.to_h { |key, value| [key.to_s, cast(find(key), value)] }
    rescue Psych::Exception => e
      raise ConfigurationError, "#{PATH} isn't valid YAML: #{e.message}"
    rescue ArgumentError => e
      raise ConfigurationError, "#{PATH}: #{e.message}"
    end

    # Sets one option from what was typed ("off", "4", "none"...). Returns the stored value.
    def change(key, value, root: PlanDriven.configuration.root_path)
      option = find(key)
      values = read(root)
      values[option.key] = cast(option, value)
      write(values, root)
      values[option.key]
    end

    # Back to what the initializer (or the gem) sets.
    def reset(key, root: PlanDriven.configuration.root_path)
      option = find(key)
      values = read(root)
      raise ArgumentError, "#{option.key} isn't changed in #{PATH}" unless values.key?(option.key)

      values.delete(option.key)
      write(values, root)
    end

    def origin(key, config: PlanDriven.configuration)
      return "settings" if config.settings.key?(key.to_s)

      config.initializer_value(key) == recommended(key) ? "default" : "initializer"
    end

    def recommended(key)
      Configuration.new.initializer_value(key)
    end

    def label(value)
      case value
      when true then "on"
      when false then "off"
      when nil then "no limit"
      else value.to_s
      end
    end

    def cast(option, value)
      text = value.to_s.strip.downcase
      case option.type
      when :boolean then boolean(option, value, text)
      when :choice
        option.choices.include?(text) or
          raise ArgumentError, "#{option.key} is one of #{option.choices.join(", ")}, not #{value.inspect}"
        text
      else integer(option, value, text)
      end
    end

    def boolean(option, value, text)
      return value if [true, false].include?(value)
      return true if ON.include?(text)
      return false if OFF.include?(text)

      raise ArgumentError, "#{option.key} is on or off, not #{value.inspect}"
    end

    def integer(option, value, text)
      return if option.blank && (value.nil? || text.empty? || NONE.include?(text))

      number = Integer(text, exception: false)
      unless number && number >= option.minimum
        raise ArgumentError, "#{option.key} is a whole number of at least #{option.minimum}" \
                             "#{" (or none)" if option.blank}, not #{value.inspect}"
      end
      number
    end

    def write(values, root)
      file = path(root)
      return file.tap { FileUtils.rm_f(file) } if values.empty?

      FileUtils.mkdir_p(file.dirname)
      file.write(HEADER + YAML.dump("settings" => values).delete_prefix("---\n"))
      file
    end
  end
end
