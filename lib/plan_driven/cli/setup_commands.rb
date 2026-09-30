# frozen_string_literal: true

module PlanDriven
  class CLI
    # Keys and a health check. These work outside a Rails application too.
    module SetupCommands
      PROMPTS = {
        "openai_api_key" => "OpenAI API key (drafting plans and tickets)",
        "anthropic_api_key" => "Anthropic API key (optional, if you draft with Claude)",
        "cursor_api_key" => "Cursor API key (cloud agents, and drafting with llm_provider :cursor)",
        "github_token" => "GitHub token with repo scope (issues, pull requests, merge)"
      }.freeze

      def cmd_configure
        ui.heading "plan-driven keys"
        ui.muted "Stored in #{Credentials.path} (0600). Keys already in the environment are used as they are."
        PROMPTS.each do |name, label|
          source = Credentials.source(name)
          if source
            ui.muted "  #{label}: set (#{source})"
            next unless ui.confirm?("  Replace it in #{Credentials.path}?")
          end
          value = ui.secret("  #{label}, Enter to skip:")
          next if value.empty?

          Credentials.store(name, value)
          ui.success "  stored"
        end
      end

      def cmd_doctor
        ui.heading "plan-driven #{PlanDriven::VERSION}"
        check_application
        ui.muted "LLM: #{LLM.new.label}"
        check_cursor_llm
        Credentials::KEYS.each_key do |name|
          next if unused_llm_key?(name)

          source = Credentials.source(name)
          source ? ui.success("#{name}: #{source}") : ui.warn("#{name}: not set")
        end
        repository = Repository.slug
        repository ? ui.success("GitHub repository: #{repository}") : ui.warn("GitHub repository: none found")
        browser = Renderer::PDF.browser
        browser ? ui.success("PDF: #{File.basename(browser)}") : ui.warn("PDF: no Chrome or Chromium, HTML only")
        check_cursor
      end

      private

      # Outside an app the keys can still be checked; inside one, the initializer decides the
      # provider and repository, so boot it first.
      def check_application
        return ui.muted("Not in a Rails application; showing defaults.") unless File.exist?("config/environment.rb")

        boot_application
        ui.success "Rails application: plan_driven tables present"
      rescue Error => e
        ui.error e.message
      end

      def check_agent_model(agents)
        model = PlanDriven.configuration.agent_model
        return ui.warn("Agent model: Cursor's default. Set config.agent_model if agents fail to start.") unless model

        if agents.model_ids.include?(model)
          ui.success "Agent model: #{model}"
        else
          ui.error "Agent model: #{model} isn't available to this key; `GET /v1/models` lists the ones that are"
        end
      end

      def unused_llm_key?(name)
        %w[openai_api_key anthropic_api_key].include?(name) && name != PlanDriven.configuration.llm_key_name.to_s
      end

      def check_cursor_llm
        config = PlanDriven.configuration
        return unless config.llm_provider.to_sym == :cursor

        ok, detail = CursorLLM.new(config).check
        ok ? ui.success("Cursor SDK: #{detail}") : ui.error("Cursor SDK: #{detail}")
      end

      def check_cursor
        return check_local_agents if PlanDriven.configuration.agent_provider.to_sym == :local
        return unless Credentials.fetch(:cursor_api_key)

        agents = CursorAgents.new
        info = agents.me
        ui.success "Cursor API: #{info["userEmail"] || info["apiKeyName"] || "connected"}"
        check_agent_model(agents)
      rescue Error => e
        ui.error "Cursor API: #{e.message}"
      end

      def check_local_agents
        command = PlanDriven.configuration.agent_command.to_s
        return ui.error("Agents: local, but config.agent_command isn't set") if command.empty?

        program = Shellwords.split(command).first
        found = ENV["PATH"].to_s.split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, program)) }
        found ? ui.success("Agents: local, #{command}") : ui.error("Agents: #{program} isn't on the PATH")
      end
    end
  end
end
