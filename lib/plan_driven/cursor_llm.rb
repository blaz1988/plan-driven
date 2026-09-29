# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

module PlanDriven
  # Drafting through a Cursor agent (Claude Opus, GPT, Composer...) on the user's Cursor account.
  # The agent runs locally with read-only tools, so it can read the application's code while it
  # writes, and can't change a file. It goes through the Cursor SDK, which is Node, via
  # cursor_llm.mjs.
  class CursorLLM
    BRIDGE = File.expand_path("cursor_llm.mjs", __dir__)

    def initialize(config)
      @config = config
    end

    def chat(system:, messages:)
      data = run_bridge(JSON.generate(model: @config.llm_model, prompt: prompt(system, messages),
                                      cwd: @config.root_path.to_s, sdkPaths: Array(@config.cursor_sdk_path)))
      LLM::Reply.new(text: data["text"].to_s, input_tokens: data.dig("usage", "input"),
                     output_tokens: data.dig("usage", "output"))
    end

    # [ok, detail] for doctor: whether Node can load the SDK.
    def check
      out, status = Open3.capture2e(@config.node_command, BRIDGE, "--check", @config.root_path.to_s,
                                    *Array(@config.cursor_sdk_path))
      data = parse(out)
      [status.success?, data["error"] || "Node #{data["node"]}, @cursor/sdk found"]
    rescue Errno::ENOENT
      [false, "#{@config.node_command} not found; the Cursor SDK needs Node 22.13+"]
    end

    private

    def prompt(system, messages)
      turns = messages.map do |message|
        message = message.to_h.stringify_keys
        "## #{message["role"]}\n\n#{message["content"]}"
      end
      <<~PROMPT
        #{system}

        You are inside the application's repository and may read any file to ground your answer in
        the real code. Don't try to change files. Reply with the JSON object only, no prose around it.

        # Conversation

        #{turns.join("\n\n")}
      PROMPT
    end

    def run_bridge(input)
      key = @config.llm_api_key or
        raise ConfigurationError, "No Cursor API key. Run `plan-driven configure` or set CURSOR_API_KEY."

      out, err, status = Timeout.timeout(@config.request_timeout) do
        Open3.capture3({ "CURSOR_API_KEY" => key }, @config.node_command, BRIDGE, stdin_data: input)
      end
      data = parse(out)
      return data if status.success? && !data.key?("error")

      raise ProviderError, "cursor: #{data["error"] || err.to_s.strip.last(300).presence || "agent failed"}"
    rescue Timeout::Error
      raise ProviderError, "cursor: no answer within #{@config.request_timeout}s (config.request_timeout)"
    rescue Errno::ENOENT
      raise ConfigurationError, "#{@config.node_command} not found; the Cursor SDK needs Node 22.13+ " \
                                "(set config.node_command or PLAN_DRIVEN_NODE)"
    end

    def parse(out)
      JSON.parse(out.to_s.strip.lines.last.to_s)
    rescue JSON::ParserError
      {}
    end
  end
end
