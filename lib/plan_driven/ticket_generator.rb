# frozen_string_literal: true

module PlanDriven
  # Splits an approved plan into tickets. Deterministic fixes come first, then the guard; errors
  # go back to the model as a list, the same way plans are repaired.
  class TicketGenerator
    Result = Struct.new(:tickets, :report, :attempts, keyword_init: true)

    FIELDS = <<~TEXT.freeze
      key: "T1", "T2", ... in delivery order
      title: short, imperative ("Migration: Add formable columns to forms")
      kind: one of #{Ticket::KINDS.join(", ")}
      type: TASK, STORY or BUG
      story: "I want ..., so that ..." (required for STORY)
      description: what to build, precise enough for a developer who hasn't read the plan
      acceptance_criteria: array of testable statements, each one becomes a Cucumber scenario
      implementation_notes: file paths, column mappings, code hints (optional)
      estimate: story points
      depends_on: keys of tickets that must be merged first
      touches: table names this ticket changes or reads in a new way
    TEXT

    def initialize(llm: LLM.new, schema: SchemaContext.new, config: PlanDriven.configuration)
      @llm = llm
      @schema = schema
      @config = config
    end

    def generate(plan, instruction: nil)
      content = request(plan)
      content += "\n\nThe reviewer asks for this breakdown: #{instruction}" if instruction.present?
      messages = [{ role: "user", content: content }]
      attempts = 0

      loop do
        attempts += 1
        reply = @llm.chat(system: system_prompt, messages: messages)
        begin
          drafted = parse(reply.text)
        rescue InvalidResponseError => e
          raise if attempts > @config.max_repair_attempts

          messages += [{ role: "assistant", content: reply.text },
                       { role: "user",
                         content: "That reply can't be used: #{e.message}. Reply with the JSON object only." }]
          next
        end
        report = Guards::Report.new
        tickets = Guards::TicketNormalizer.new(drafted, config: @config).call(report)
        report.merge!(Guards::TicketGuard.new(tickets, plan_sections: plan.sections, schema: @schema,
                                                       config: @config).call)
        if report.ok? || attempts > @config.max_repair_attempts
          return Result.new(tickets: tickets, report: report, attempts: attempts)
        end

        messages += [{ role: "assistant", content: reply.text }, { role: "user", content: repair(report) }]
      end
    end

    def system_prompt
      <<~PROMPT
        You split an approved Rails implementation plan into tickets. Each ticket becomes one
        pull request written by a coding agent and reviewed by a human, so each must merge on
        its own without breaking the application.

        Order the work the way zero-downtime Rails changes ship: migrations that add, dual
        writes, backfills, switching reads, then cleanup that removes. A ticket may only depend
        on tickets before it. Keep tickets small: at most #{@config.max_estimate} points on the
        scale #{@config.estimate_scale.join(", ")}. Schema changes get their own migration tickets.
        Split code by behaviour, not by layer: each code ticket delivers one thing a user can do,
        with its model, service, controller, view and specs together, so its acceptance criteria
        can be proven by Cucumber scenarios.

        Reply with one JSON object: {"tickets": [ ... ]}. Each ticket has:
        #{FIELDS}
      PROMPT
    end

    private

    def request(plan)
      sections = plan.sections.map { |key, value| "## #{@config.template[key]&.title || key}\n#{value}" }
      "Plan #{plan.key}: #{plan.title}\n\n#{sections.join("\n\n")}"
    end

    def repair(report)
      "These problems must be fixed:\n#{report.errors.map { |error| "- #{error}" }.join("\n")}\n\n" \
        "Reply with the full JSON again, every ticket included."
    end

    def parse(text)
      tickets = JsonReply.parse(text)["tickets"]
      raise InvalidResponseError, "the reply had no \"tickets\" array" unless tickets.is_a?(Array)

      tickets
    end
  end
end
