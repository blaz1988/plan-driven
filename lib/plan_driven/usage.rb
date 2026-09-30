# frozen_string_literal: true

module PlanDriven
  # What a plan cost to deliver: tokens for every model call and agent run, recorded as events
  # (`llm.usage`, `agent.usage`), and dollars when config.token_prices has a price for the model.
  # Prices change and differ per account, so the gem ships none: put in what your provider charges.
  module Usage
    FIELDS = %w[input_tokens output_tokens cache_write_tokens cache_read_tokens].freeze

    Row = Struct.new(:step, :ticket, :model, :calls, :tokens, :duration_ms, :cost, keyword_init: true) do
      def total_tokens
        tokens.values.sum
      end
    end

    module_function

    # Dollars for these tokens, or nil when the model has no price. Prices are per million tokens:
    #   config.token_prices = { "your-model-id" => { input: 3.0, output: 15.0, cache_write: 3.75, cache_read: 0.3 } }
    def cost(model, tokens, config: PlanDriven.configuration)
      price = config.token_prices.to_h.transform_keys(&:to_s)[model.to_s] or return
      price = price.transform_keys(&:to_s)
      FIELDS.sum { |field| tokens[field].to_i * price.fetch(field.delete_suffix("_tokens"), 0).to_f } / 1_000_000.0
    end

    # What the metered model spent in one step, as an `llm.usage` event.
    def record_llm(plan, llm, step, actor:)
      spent = llm.take
      return if spent["calls"].zero?

      plan.log!("llm.usage", actor: actor, step: step, model: llm.model, **spent.symbolize_keys)
    end

    # One finished agent run. Usage is bookkeeping: a provider that can't report it mustn't stop
    # the ticket moving.
    def record_agent(ticket, run, agents, actor:, config: PlanDriven.configuration)
      tokens = agents.respond_to?(:usage) ? agents.usage(ticket.agent_id, run.id) : {}
      step = ticket.plan.events.exists?(name: "agent.usage", ticket: ticket) ? "agent follow-up" : "agent run"
      ticket.plan.log!("agent.usage", actor: actor, ticket: ticket, step: step, run: run.id,
                                      model: config.agent_model || "#{config.agent_provider} default",
                                      calls: 1, duration_ms: run.duration_ms, **tokens.to_h.symbolize_keys)
    rescue Error => e
      ticket.plan.log!("agent.usage", actor: actor, ticket: ticket, run: run.id, error: e.message[0, 200])
    end

    def tokens_from(payload)
      FIELDS.to_h { |field| [field, payload.to_h[field].to_i] }
    end

    def rows(plan, config: PlanDriven.configuration)
      plan.events.where(name: %w[llm.usage agent.usage]).order(:created_at).map do |event|
        payload = event.payload.to_h
        tokens = tokens_from(payload)
        Row.new(step: payload["step"], ticket: event.ticket&.key, model: payload["model"], calls: payload["calls"].to_i,
                tokens: tokens, duration_ms: payload["duration_ms"],
                cost: cost(payload["model"], tokens, config: config))
      end
    end

    def totals(rows)
      tokens = FIELDS.to_h { |field| [field, rows.sum { |row| row.tokens[field] }] }
      costs = rows.map(&:cost)
      { tokens: tokens, total_tokens: tokens.values.sum, cost: costs.any?(&:nil?) ? nil : costs.sum,
        priced_cost: costs.compact.sum, unpriced: rows.select { |row| row.cost.nil? }.map(&:model).uniq }
    end

    def format_tokens(count)
      count >= 1_000_000 ? format("%.2fM", count / 1_000_000.0) : count.to_s.reverse.scan(/\d{1,3}/).join(",").reverse
    end

    def format_cost(cost)
      cost ? format("$%.2f", cost) : "-"
    end
  end

  # Wraps any model client and counts what each step spends, so Delivery can record it.
  class MeteredLLM
    def initialize(llm)
      @llm = llm
      reset
    end

    def chat(**options)
      reply = @llm.chat(**options)
      @calls += 1
      @input += reply.input_tokens.to_i
      @output += reply.output_tokens.to_i
      reply
    end

    def label
      @llm.label
    end

    def model
      label.split("/", 2).last
    end

    # What was spent since the last take, as an event payload.
    def take
      spent = { "calls" => @calls, "input_tokens" => @input, "output_tokens" => @output }
      reset
      spent
    end

    private

    def reset
      @calls = 0
      @input = 0
      @output = 0
    end
  end
end
