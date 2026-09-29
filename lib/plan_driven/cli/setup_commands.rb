# frozen_string_literal: true

module PlanDriven
  class CLI
    # Keys and a health check. These work outside a Rails application too.
    module SetupCommands
      PROMPTS = {
        "openai_api_key" => "OpenAI API key (drafting plans and tickets)",
        "anthropic_api_key" => "Anthropic API key (optional, if you draft with Claude)",
        "cursor_api_key" => "Cursor API key (cloud agents; cursor.com/dashboard -> Integrations)",
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
        Credentials::KEYS.each_key do |name|
          next if name == unused_llm_key

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

      def unused_llm_key
        PlanDriven.configuration.llm_provider.to_sym == :anthropic ? "openai_api_key" : "anthropic_api_key"
      end

      def check_cursor
        return unless Credentials.fetch(:cursor_api_key)

        info = CursorAgents.new.me
        ui.success "Cursor API: #{info["userEmail"] || info["apiKeyName"] || "connected"}"
      rescue Error => e
        ui.error "Cursor API: #{e.message}"
      end
    end
  end
end
