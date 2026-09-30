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
    end
  end
end
