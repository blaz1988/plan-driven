# frozen_string_literal: true

module PlanDriven
  # The services plan_driven talks to, which of them this app's configuration uses, and a check
  # that a key works before `plan-driven connect` stores it.
  module Connections
    Service = Struct.new(:name, :title, :key, :purpose, :url, keyword_init: true) do
      def env
        Credentials::KEYS.fetch(key)
      end
    end

    SERVICES = [
      Service.new(name: "cursor", title: "Cursor", key: "cursor_api_key",
                  purpose: "Cloud agents, one per ticket, and drafting with llm_provider :cursor",
                  url: "https://cursor.com/dashboard?tab=integrations"),
      Service.new(name: "openai", title: "OpenAI", key: "openai_api_key",
                  purpose: "Drafting plans and tickets with llm_provider :openai",
                  url: "https://platform.openai.com/api-keys"),
      Service.new(name: "anthropic", title: "Anthropic", key: "anthropic_api_key",
                  purpose: "Drafting plans and tickets with llm_provider :anthropic",
                  url: "https://console.anthropic.com/settings/keys"),
      Service.new(name: "github", title: "GitHub", key: "github_token",
                  purpose: "Issues, pull requests, reviews and merges",
                  url: "https://github.com/settings/personal-access-tokens")
    ].freeze

    module_function

    def find(name)
      SERVICES.find { |service| service.name == name.to_s.downcase } or
        raise ArgumentError, "Connect what? One of: #{SERVICES.map(&:name).join(", ")}"
    end

    # The services this app needs with its current configuration.
    def needed(config = PlanDriven.configuration)
      names = ["github"]
      names << "cursor" if config.agent_provider.to_sym == :cursor || config.llm_provider.to_sym == :cursor
      names << config.llm_provider.to_s if %i[openai anthropic].include?(config.llm_provider.to_sym)
      SERVICES.select { |service| names.include?(service.name) }
    end

    # Who the key belongs to, or a ProviderError when the service refuses it.
    def verify(service, key, config = PlanDriven.configuration)
      case service.name
      when "cursor"
        info = CursorAgents.new(api_key: key, config: config).me
        "connected as #{info["userEmail"] || info["apiKeyName"] || "this key"}"
      when "github"
        headers = { "Authorization" => "Bearer #{key}", "Accept" => "application/vnd.github+json" }
        "connected as #{get(service, "https://api.github.com/user", headers)["login"]}"
      when "openai"
        base = config.llm_provider.to_sym == :openai && config.llm_api_base ? config.llm_api_base : "https://api.openai.com/v1"
        get(service, "#{base.chomp("/")}/models", "Authorization" => "Bearer #{key}")
        "the key works"
      when "anthropic"
        get(service, "https://api.anthropic.com/v1/models", "x-api-key" => key, "anthropic-version" => "2023-06-01")
        "the key works"
      end
    end

    def get(service, url, headers)
      response = HTTP.request(:get, url, headers: headers.merge("User-Agent" => "plan_driven"), timeout: 30)
      return response.json if response.success?

      raise ProviderError, "#{service.title} refused the key (HTTP #{response.status})"
    end
  end
end
