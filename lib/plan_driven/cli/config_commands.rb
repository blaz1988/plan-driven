# frozen_string_literal: true

module PlanDriven
  class CLI
    # The interview's questions, and connecting the services with a key that's checked first.
    module ConfigCommands
      def cmd_questions
        config = PlanDriven.configuration
        ui.table(%w[Key Source Asks], config.template.asked.map do |section|
          [section.key, Interview.origin(section.key, template: config.base_template), section.prompt]
        end)
        ui.muted "Changes are in #{Interview::PATH}; commit it so the team gets the same interview."
      end

      def cmd_question(key = nil)
        raise ArgumentError, "Which question? Pass its key, for example who." if key.to_s.empty?

        base = PlanDriven.configuration.base_template
        if @options[:remove]
          result = Interview.remove(key, template: base)
          ui.success(result == :removed ? "Question #{key} removed" : "Question #{key} is back to the default")
        else
          result = Interview.change(key, question_fields, template: base)
          ui.success "Question #{key} #{result}"
        end
        cmd_questions
      end

      def cmd_connect(name = nil)
        service = Connections.find(name)
        ui.muted "#{service.title}: #{service.purpose}. Get a key at #{service.url}"
        value = ui.secret("#{service.title} key:")
        raise ArgumentError, "No key given; nothing was stored." if value.empty?

        ui.say "Checking the key with #{service.title}..."
        detail = verify_connection(service, value)
        path = Credentials.store(service.key, value)
        ui.success "#{service.title}: #{detail}"
        ui.muted "  stored in #{path} (0600), never in the app"
        return if ENV[service.env].to_s.strip.empty?

        ui.warn "#{service.env} is set in this environment, and it wins over the stored key."
      end

      private

      def question_fields
        fields = { "title" => @options[:title], "question" => @options[:ask], "group" => @options[:group] }.compact
        fields["required"] = @options[:required] unless @options[:required].nil?
        fields
      end

      def verify_connection(service, value)
        Connections.verify(service, value)
      rescue Error => e
        raise ProviderError, "#{e.message}; nothing was stored."
      end
    end
  end
end
