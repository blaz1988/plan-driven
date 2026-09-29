# frozen_string_literal: true

module PlanDriven
  class Railtie < Rails::Railtie
    generators do
      require_relative "../generators/plan_driven/install_generator"
    end
  end
end
