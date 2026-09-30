# frozen_string_literal: true

module PlanDriven
  module Wizard
    # The wizard runs commands on this machine, so it only answers local requests in development
    # (or wherever config.wizard_enabled says).
    class ApplicationController < ActionController::Base
      protect_from_forgery with: :exception
      layout "plan_driven/wizard/application"
      before_action :local_only!
      helper_method :acting_as, :current_job

      helper do
        # A button that runs one command for the plan on the page, e.g. run_button("Submit", "submit").
        def run_button(label, action, fields = {}, primary: false, disabled: false)
          button_to label, run_plan_path(@plan.key),
                    params: fields.merge(do: action, step: @step), disabled: disabled,
                    class: primary ? "primary" : nil, form: { style: "display:inline" }
        end

        def markdown(text)
          PlanDriven::Renderer::HTML.convert(text).html_safe
        end

        def guard_list(report)
          safe_join([
            (tag.ul(safe_join(report.errors.map { |e| tag.li(e) }), class: "errors") if report.errors.any?),
            (tag.ul(safe_join(report.warnings.map { |w| tag.li(w) }), class: "warnings") if report.warnings.any?),
            (tag.p("#{report.passes.size} checks passed.", class: "muted") if report.passes.any?)
          ].compact)
        end
      end

      private

      def local_only!
        enabled = PlanDriven.configuration.wizard_enabled
        enabled = Rails.env.development? if enabled.nil?
        head :forbidden unless enabled && request.local?
      end

      def acting_as
        session[:plan_driven_actor].presence || PlanDriven.actor
      end

      def current_job
        return @current_job if defined?(@current_job)

        @current_job = params[:job].present? ? Job.find(params[:job]) : nil
      rescue ArgumentError
        @current_job = nil
      end

      def start(argv, stdin: nil)
        Job.start(argv, stdin: stdin, actor: session[:plan_driven_actor])
      end
    end
  end
end
