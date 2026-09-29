# frozen_string_literal: true

module PlanDriven
  class Record < ActiveRecord::Base
    self.abstract_class = true
    self.table_name_prefix = "plan_driven_"
  end
end
