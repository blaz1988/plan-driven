# frozen_string_literal: true

require "logger"

ActiveRecord::Base.logger = Logger.new(IO::NULL)
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Migration.verbose = false

# A slice of a real application: the models from a form builder plan.
ActiveRecord::Schema.define do
  create_table :business_processes, force: true do |t|
    t.string :name, null: false
    t.timestamps
  end

  create_table :forms, force: true do |t|
    t.references :business_process
    t.string :type
    t.string :name
    t.timestamps
  end

  create_table :fields, force: true do |t|
    t.string :name, null: false
    t.string :value_type
    t.boolean :required, default: false, null: false
    t.timestamps
  end

  create_table :projects, force: true do |t|
    t.string :name
    t.timestamps
  end
end

template = File.read(File.expand_path("../../lib/generators/plan_driven/templates/create_plan_driven_tables.rb.tt",
                                      __dir__))
eval(template.sub("<%= ActiveRecord::Migration.current_version %>", ActiveRecord::Migration.current_version.to_s)) # rubocop:disable Security/Eval
CreatePlanDrivenTables.migrate(:up)

class BusinessProcess < ActiveRecord::Base
  has_many :forms, dependent: :destroy
end

class Form < ActiveRecord::Base
  belongs_to :business_process, optional: true
end

class Field < ActiveRecord::Base; end
class Project < ActiveRecord::Base; end

module TestDatabase
  TABLES = %w[plan_driven_events plan_driven_evidence_runs plan_driven_approvals plan_driven_tickets
              plan_driven_plans].freeze

  def self.clean!
    TABLES.each { |table| ActiveRecord::Base.connection.execute("DELETE FROM #{table}") }
  end
end
