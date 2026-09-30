# frozen_string_literal: true

require "base64"

module PlanDriven
  # Cursor Cloud Agents API v1: one agent per ticket, running on a Cursor-hosted VM against a
  # fresh clone, opening a pull request when it finishes.
  # https://cursor.com/docs/cloud-agent/api/endpoints
  class CursorAgents
    BASE = "https://api.cursor.com/v1"
    TERMINAL = %w[FINISHED ERROR CANCELLED EXPIRED].freeze

    Run = Struct.new(:id, :agent_id, :status, :result, :branch, :pr_url, :duration_ms, keyword_init: true) do
      def terminal?
        TERMINAL.include?(status)
      end

      def finished?
        status == "FINISHED"
      end
    end

    def initialize(api_key: Credentials.fetch(:cursor_api_key), base: BASE, config: PlanDriven.configuration)
      @api_key = api_key
      @base = base
      @config = config
    end

    def launch(prompt:, repo_url:, name:)
      body = {
        prompt: { text: prompt },
        name: name[0, 100],
        repos: [{ url: repo_url, startingRef: @config.base_branch }],
        autoCreatePR: true,
        skipReviewerRequest: @config.skip_reviewer_request
      }
      body[:model] = { id: @config.agent_model } if @config.agent_model
      response = request(:post, "/agents", body)
      agent = response.fetch("agent")
      [agent, to_run(response.fetch("run"))]
    end

    def run(agent_id, run_id)
      to_run(request(:get, "/agents/#{agent_id}/runs/#{run_id}"))
    end

    def follow_up(agent_id, text)
      to_run(request(:post, "/agents/#{agent_id}/runs", { prompt: { text: text } }).fetch("run"))
    end

    # Tokens one run spent, in Usage's field names.
    def usage(agent_id, run_id)
      data = request(:get, "/agents/#{agent_id}/usage?runId=#{run_id}")
      tokens = Array(data["runs"]).first.to_h["usage"] || data["totalUsage"] || {}
      { "input_tokens" => tokens["inputTokens"].to_i, "output_tokens" => tokens["outputTokens"].to_i,
        "cache_write_tokens" => tokens["cacheWriteTokens"].to_i, "cache_read_tokens" => tokens["cacheReadTokens"].to_i }
    end

    def me
      request(:get, "/me")
    end

    # IDs and aliases of the models this key can start agents with.
    def model_ids
      Array(request(:get, "/models")["items"]).flat_map { |item| [item["id"], *Array(item["aliases"])] }.compact.uniq
    end

    private

    def to_run(data)
      branch = Array(data.dig("git", "branches")).first || {}
      Run.new(id: data["id"], agent_id: data["agentId"], status: data["status"], result: data["result"],
              branch: branch["branch"], pr_url: branch["prUrl"], duration_ms: data["durationMs"])
    end

    def request(method, path, body = nil)
      raise ConfigurationError, "No Cursor API key. Run `plan-driven configure` or set CURSOR_API_KEY." unless @api_key

      response = HTTP.request(method, "#{@base}#{path}", body: body, timeout: 60, headers: {
                                "Authorization" => "Basic #{Base64.strict_encode64("#{@api_key}:")}",
                                "Content-Type" => "application/json"
                              })
      return response.json if response.success?

      error = response.json["error"]
      message = error.is_a?(Hash) ? error["message"] || error["code"] : error
      raise ProviderError, "Cursor API returned #{response.status}: #{message || response.body.to_s[0, 200]}"
    end
  end
end
