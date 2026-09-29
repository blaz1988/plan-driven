# frozen_string_literal: true

module PlanDriven
  # Turns interview answers into the drafted sections of a plan, then keeps the model honest:
  # the guard runs on every draft, and its errors go back to the model as a list to fix.
  class Drafter
    Result = Struct.new(:sections, :report, :attempts, :assumptions, keyword_init: true)

    def initialize(llm: LLM.new, schema: SchemaContext.new, config: PlanDriven.configuration)
      @llm = llm
      @schema = schema
      @config = config
      @template = config.template
    end

    def draft(answers, title:)
      answers = answers.transform_keys(&:to_s)
      messages = [{ role: "user", content: request(answers, title) }]
      attempts = 0

      loop do
        attempts += 1
        reply = @llm.chat(system: system_prompt, messages: messages)
        begin
          parsed = parse(reply.text)
        rescue InvalidResponseError => e
          raise if attempts > @config.max_repair_attempts

          messages += [{ role: "assistant", content: reply.text },
                       { role: "user",
                         content: "That reply can't be used: #{e.message}. Reply with the JSON object only." }]
          next
        end
        sections = answers.merge(parsed.fetch("sections", {}).slice(*@template.drafted.map(&:key)))
        report = Guards::PlanGuard.new(sections, schema: @schema, template: @template).call
        if report.ok? || attempts > @config.max_repair_attempts
          return Result.new(sections: sections, report: report, attempts: attempts,
                            assumptions: Array(parsed["assumptions"]))
        end

        messages += [{ role: "assistant", content: reply.text }, { role: "user", content: repair(report) }]
      end
    end

    # One section again, with an instruction from the reviewer ("shorter", "add the index").
    def redraft(sections, key, instruction)
      section = @template[key] or raise ArgumentError, "unknown section #{key}"
      content = <<~TEXT
        The current plan, as JSON:
        #{JSON.pretty_generate(sections)}

        Rewrite only the section "#{section.key}" (#{section.title}). Reviewer's instruction: #{instruction}
        Guidance for this section: #{section.guidance}
        Reply with JSON: {"sections": {"#{section.key}": "..."}}
      TEXT
      reply = @llm.chat(system: system_prompt, messages: [{ role: "user", content: content }])
      parse(reply.text).dig("sections", section.key).to_s
    end

    def system_prompt
      <<~PROMPT
        You write implementation plans for a Ruby on Rails team. A plan is read by developers,
        QA, DevOps and a director, then split into tickets that coding agents implement.

        Write in plain, specific English. Name real models, tables, columns and file paths.
        Follow Rails conventions. Changes are additive and legacy-safe: expand, dual write,
        backfill, switch reads, then contract. Never describe something as existing unless it
        is in the schema you are given. When you don't know, say so under Outstanding questions.

        Reply with one JSON object and nothing else:
        {"sections": {"<key>": "<markdown>", ...}, "assumptions": ["..."]}

        Sections to write, by key:
        #{@template.drafted.map { |section| "- #{section.key} (#{section.title}): #{section.guidance}" }.join("\n")}
      PROMPT
    end

    private

    def request(answers, title)
      asked = @template.asked.filter_map do |section|
        value = answers[section.key].to_s.strip
        "#{section.title}:\n#{value}" unless value.empty?
      end
      <<~TEXT
        Plan title: #{title}

        The team's answers:
        #{asked.join("\n\n")}

        The application's schema:
        #{@schema.to_prompt}
        #{"\nMore context:\n#{@config.extra_context}" if @config.extra_context}
      TEXT
    end

    def repair(report)
      <<~TEXT
        The plan was checked and these problems must be fixed:
        #{report.errors.map { |error| "- #{error}" }.join("\n")}

        Reply with the full JSON again, every section included.
      TEXT
    end

    def parse(text)
      parsed = JsonReply.parse(text)
      raise InvalidResponseError, "the reply had no \"sections\" object" unless parsed["sections"].is_a?(Hash)

      parsed["sections"] = parsed["sections"].transform_values { |value| stringify(value) }
      parsed
    end

    def stringify(value)
      case value
      when Array then value.map { |item| "- #{item}" }.join("\n")
      when Hash then value.map { |heading, body| "### #{heading}\n#{stringify(body)}" }.join("\n\n")
      else value.to_s
      end
    end
  end
end
