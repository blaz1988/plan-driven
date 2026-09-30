# frozen_string_literal: true

module PlanDriven
  module Wizard
    # The interview's questions and the service connections. Like every other page, it only
    # reads; each form runs one `plan-driven` command.
    class ConfigurationController < ApplicationController
      def show
        config = PlanDriven.configuration
        @template = config.template
        @base = config.base_template
        @needed = Connections.needed(config).map(&:name)
      end

      def question
        job = start(Commands.argv("question", question_fields))
        redirect_to configuration_path(job: job.id, anchor: "questions")
      rescue ArgumentError => e
        redirect_to configuration_path(anchor: "questions"), alert: e.message
      end

      def connect
        service = Connections.find(params[:service])
        key = params[:api_key].to_s.strip
        raise ArgumentError, "Paste the #{service.title} key first." if key.empty?

        job = start(Commands.argv("connect", service: service.name), stdin: "#{key}\n")
        redirect_to configuration_path(job: job.id, anchor: "connections")
      rescue ArgumentError => e
        redirect_to configuration_path(anchor: "connections"), alert: e.message
      end

      def check
        job = start(Commands.argv(params[:do] == "questions" ? "questions" : "doctor", {}))
        redirect_to configuration_path(job: job.id, anchor: params[:do] == "questions" ? "questions" : "connections")
      end

      private

      # Only what differs from the question as it is now, so an unchanged field stays the default.
      def question_fields
        key = params[:key].to_s.strip
        return { "key" => key, "remove" => "1" } if params[:remove].present?

        current = PlanDriven.configuration.template[key]
        fields = changed_text(current).merge("key" => key)
        required = params[:required] == "1"
        fields["required"] = required ? "1" : "0" if current.nil? || required != current.required
        fields
      end

      def changed_text(current)
        %w[title question group].each_with_object({}) do |name, fields|
          value = params[name].to_s.strip
          next if value.empty? || (current && value == current.public_send(name).to_s)

          fields[name] = value
        end
      end
    end
  end
end
