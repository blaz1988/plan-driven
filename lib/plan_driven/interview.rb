# frozen_string_literal: true

require "fileutils"
require "yaml"

module PlanDriven
  # The interview as the team changed it, with `plan-driven question` or the wizard's
  # Configuration page. It lives in the application, in config/plan_driven/interview.yml, so it
  # is committed and everyone on the team gets the same questions:
  #
  #     questions:
  #       who:
  #         question: Who owns it, and who reviews the pull requests?
  #       success_metric:
  #         title: Success metric
  #         question: How will we know it worked?
  #         group: Overview
  #         required: false
  #
  # A key the template already asks changes that question; any other key adds one. Drafted
  # sections belong to the model and can't be changed here.
  module Interview
    PATH = "config/plan_driven/interview.yml"
    KEY = /\A[a-z][a-z0-9_]{1,39}\z/
    FIELDS = %w[title question group required].freeze
    HEADER = "# The plan_driven interview, as changed with `plan-driven question` or the wizard.\n" \
             "# Commit it: everyone on the team gets the same questions.\n"

    module_function

    def path(root = PlanDriven.configuration.root_path)
      Pathname(root).join(PATH)
    end

    def read(root = PlanDriven.configuration.root_path)
      file = path(root)
      return {} unless file.exist?

      data = YAML.safe_load(file.read) || {}
      questions = data.is_a?(Hash) ? data["questions"] : nil
      questions.is_a?(Hash) ? questions.transform_values { |fields| fields.to_h.slice(*FIELDS) } : {}
    rescue Psych::Exception => e
      raise ConfigurationError, "#{PATH} isn't valid YAML: #{e.message}"
    end

    # The template with the team's changes applied. Asked sections keep their place; an added
    # question goes after the last section of its group.
    def apply(template, root = PlanDriven.configuration.root_path)
      changes = read(root)
      return template if changes.empty?

      sections = template.sections.map(&:dup)
      changes.each do |key, fields|
        existing = sections.find { |section| section.key == key }
        next if existing&.drafted?

        if existing
          update(existing, fields)
        else
          insert(sections, build(key, fields))
        end
      end
      Template.new(sections)
    end

    # Adds or changes one question. Returns :added or :changed.
    def change(key, fields, template:, root: PlanDriven.configuration.root_path)
      key = validate_key(key, template)
      fields = normalize(fields)
      raise ArgumentError, "Nothing to change: pass --title, --ask, --group, --required or --optional" if fields.empty?

      changes = read(root)
      changes[key] = changes.fetch(key, {}).merge(fields)
      added = template[key].nil?
      validate_new(changes[key]) if added
      write(changes, root)
      added ? :added : :changed
    end

    # Removes an added question, or puts a changed one back to the template's default.
    def remove(key, template:, root: PlanDriven.configuration.root_path)
      changes = read(root)
      raise ArgumentError, "#{key} has no changes to remove" unless changes.key?(key.to_s)

      changes.delete(key.to_s)
      write(changes, root)
      template[key].nil? ? :removed : :reset
    end

    def origin(key, template:, root: PlanDriven.configuration.root_path)
      return "default" unless read(root).key?(key.to_s)

      template[key].nil? ? "added" : "changed"
    end

    def update(section, fields)
      section.title = fields["title"] if fields["title"].to_s.strip != ""
      section.question = fields["question"] if fields["question"].to_s.strip != ""
      section.group = fields["group"] if Template::GROUPS.include?(fields["group"])
      return unless fields.key?("required")

      section.required = fields["required"] == true
      section.min_words = section.required ? [section.min_words.to_i, 1].max : 0
    end

    def build(key, fields)
      required = fields["required"] == true
      group = Template::GROUPS.include?(fields["group"]) ? fields["group"] : "Overview"
      Template::Section.new(
        key: key, title: fields["title"].to_s, group: group, source: :ask, required: required,
        min_words: required ? 1 : 0, question: fields["question"].to_s,
        guidance: "The team's answer to: #{fields["question"]}"
      )
    end

    def normalize(fields)
      fields = fields.to_h.transform_keys(&:to_s).slice(*FIELDS).compact
      %w[title question].each { |name| fields[name] = fields[name].to_s.strip if fields.key?(name) }
      validate_group(fields["group"]) if fields.key?("group")
      fields
    end

    def validate_new(fields)
      raise ArgumentError, "A new question needs --title" if fields["title"].to_s.empty?
      raise ArgumentError, "A new question needs --ask \"the question\"" if fields["question"].to_s.empty?
    end

    def insert(sections, section)
      index = sections.rindex { |existing| existing.group == section.group }
      index ? sections.insert(index + 1, section) : sections << section
    end

    def validate_key(key, template)
      key = key.to_s.strip
      unless key.match?(KEY)
        raise ArgumentError,
              "#{key.inspect} isn't a question key: lower case letters, digits and _, like success_metric"
      end
      if template[key]&.drafted?
        raise ArgumentError, "#{key} is drafted by the model, not asked; only asked questions can be changed"
      end

      key
    end

    def validate_group(group)
      return if Template::GROUPS.include?(group)

      raise ArgumentError, "Unknown group #{group.inspect}. One of: #{Template::GROUPS.join(", ")}"
    end

    def write(changes, root)
      file = path(root)
      return file.tap { FileUtils.rm_f(file) } if changes.empty?

      FileUtils.mkdir_p(file.dirname)
      file.write(HEADER + YAML.dump("questions" => changes).delete_prefix("---\n"))
      file
    end
  end
end
