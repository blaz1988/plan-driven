# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module PlanDriven
  module Generators
    # bin/rails generate plan_driven:install
    class InstallGenerator < Rails::Generators::Base
      include ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def copy_migration
        migration_template "create_plan_driven_tables.rb.tt", "db/migrate/create_plan_driven_tables.rb"
      end

      def copy_initializer
        template "plan_driven.rb", "config/initializers/plan_driven.rb"
      end

      def create_docs_directory
        create_file "docs/plans/.keep"
      end

      def show_next_steps
        say <<~TEXT

          Next:
            bin/rails db:migrate
            bundle exec plan-driven configure   # keys for the LLM, Cursor and GitHub
            bundle exec plan-driven new "Short title of the change"
        TEXT
      end
    end
  end
end
