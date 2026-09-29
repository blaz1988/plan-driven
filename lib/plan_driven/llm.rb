# frozen_string_literal: true

module PlanDriven
  # One call: a system prompt and messages in, text out. Planning is where a stronger model pays
  # for itself, so the default is a GPT-4.1 or Claude Sonnet class model, not a mini one, and
  # :cursor drafts with any model on the user's Cursor account (see CursorLLM).
  class LLM
    OPENAI_BASE = "https://api.openai.com/v1"
    ANTHROPIC_BASE = "https://api.anthropic.com/v1"

    Reply = Struct.new(:text, :input_tokens, :output_tokens, keyword_init: true)

    attr_reader :config

    def initialize(config = PlanDriven.configuration, client: nil)
      @config = config
      @client = client
    end

    def chat(system:, messages:, max_tokens: 8000)
      return wrap(@client.call(system: system, messages: messages)) if @client

      case config.llm_provider.to_sym
      when :cursor then CursorLLM.new(config).chat(system: system, messages: messages)
      when :anthropic then anthropic(system, messages, max_tokens)
      else openai(system, messages, max_tokens)
      end
    end

    def label
      "#{config.llm_provider}/#{config.llm_model}"
    end

    private

    def anthropic?
      config.llm_provider.to_sym == :anthropic
    end

    def api_key!
      config.llm_api_key or
        raise ConfigurationError, "No API key for #{config.llm_provider}. Run `plan-driven configure` or set " \
                                  "#{anthropic? ? "ANTHROPIC_API_KEY" : "OPENAI_API_KEY"}."
    end

    def openai(system, messages, max_tokens)
      body = { model: config.llm_model, temperature: config.temperature, max_completion_tokens: max_tokens,
               response_format: { type: "json_object" },
               messages: [{ role: "system", content: system }] + messages }
      response = post("#{config.llm_api_base || OPENAI_BASE}/chat/completions", body,
                      "Authorization" => "Bearer #{api_key!}")
      usage = response["usage"] || {}
      Reply.new(text: response.dig("choices", 0, "message", "content").to_s,
                input_tokens: usage["prompt_tokens"], output_tokens: usage["completion_tokens"])
    end

    def anthropic(system, messages, max_tokens)
      body = { model: config.llm_model, system: system, max_tokens: max_tokens, temperature: config.temperature,
               messages: messages }
      response = post("#{config.llm_api_base || ANTHROPIC_BASE}/messages", body,
                      "x-api-key" => api_key!, "anthropic-version" => "2023-06-01")
      usage = response["usage"] || {}
      Reply.new(text: Array(response["content"]).filter_map { |part| part["text"] }.join,
                input_tokens: usage["input_tokens"], output_tokens: usage["output_tokens"])
    end

    def post(url, body, headers)
      response = HTTP.request(:post, url, headers: headers.merge("Content-Type" => "application/json"),
                                          body: body, timeout: config.request_timeout)
      return response.json if response.success?

      message = response.json.dig("error", "message") || response.body.to_s[0, 200]
      raise ProviderError, "#{config.llm_provider} returned #{response.status}: #{message}"
    end

    def wrap(value)
      value.is_a?(Reply) ? value : Reply.new(text: value.to_s)
    end
  end
end
