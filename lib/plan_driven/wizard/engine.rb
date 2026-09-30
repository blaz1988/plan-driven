# frozen_string_literal: true

module PlanDriven
  module Wizard
    # Mounted by the install generator, in development only:
    #
    #   mount PlanDriven::Wizard::Engine, at: "/plan_driven" if Rails.env.development?
    class Engine < ::Rails::Engine
      isolate_namespace PlanDriven::Wizard
      engine_name "plan_driven_wizard"
      config.root = File.expand_path("../../..", __dir__)

      # Keys pasted on the Configuration page go to `plan-driven connect` on stdin, never to the log.
      initializer "plan_driven_wizard.filter_parameters" do |app|
        app.config.filter_parameters += [:api_key]
      end
    end
  end
end
