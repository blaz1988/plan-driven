# frozen_string_literal: true

module PlanDriven
  # What the application looks like, read from the database connection and ActiveRecord models.
  # The model is told this so a plan describes the real schema, and the guards use it to catch a
  # plan that describes tables or columns that don't exist.
  class SchemaContext
    IGNORED_TABLES = /\A(schema_migrations|ar_internal_metadata|plan_driven_|active_storage_|action_text_|
                     action_mailbox_|solid_(queue|cache|cable)_)/x

    Model = Struct.new(:name, :table, :path, :associations, keyword_init: true)

    def initialize(connection: ActiveRecord::Base.connection, root: PlanDriven.configuration.root_path)
      @connection = connection
      @root = Pathname(root)
    end

    def adapter
      @connection.adapter_name
    end

    def tables
      @tables ||= @connection.tables.grep_v(IGNORED_TABLES).sort
    end

    def columns(table)
      @columns ||= {}
      @columns[table.to_s] ||= @connection.columns(table.to_s).map do |column|
        [column.name, column.sql_type_metadata.type.to_s, column.null ? nil : "not null"].compact
      end
    end

    def column?(table, column)
      tables.include?(table.to_s) && columns(table).any? { |name, *| name == column.to_s }
    end

    def table?(table)
      tables.include?(table.to_s)
    end

    def models
      @models ||= load_models
    end

    def model_names
      models.map(&:name)
    end

    def model?(name)
      model_names.include?(name.to_s)
    end

    def to_prompt
      return "The application has no tables yet." if tables.empty?

      by_table = models.group_by(&:table)
      tables.map { |table| describe(table, by_table[table]) }.join("\n\n")
    end

    private

    def describe(table, table_models)
      header = if table_models&.any?
                 "#{table_models.map { |model| "#{model.name} (#{model.path || "no file"})" }.join(", ")} -> #{table}"
               else
                 "#{table} (no model)"
               end
      lines = [header, "  columns: #{columns(table).map { |parts| parts.join(":") }.join(", ")}"]
      Array(table_models).flat_map(&:associations).uniq.each { |association| lines << "  #{association}" }
      lines.join("\n")
    end

    def load_models
      Rails.application.eager_load! if defined?(Rails) && Rails.respond_to?(:application) && Rails.application
      ActiveRecord::Base.descendants.filter_map do |klass|
        next if klass.abstract_class? || klass.name.nil? || klass.name.start_with?("PlanDriven::")
        next unless table?(klass.table_name)

        Model.new(name: klass.name, table: klass.table_name, path: model_path(klass),
                  associations: klass.reflect_on_all_associations.map { |reflection| association_line(reflection) })
      rescue StandardError
        nil
      end.sort_by(&:name)
    end

    def association_line(reflection)
      line = "#{reflection.macro} :#{reflection.name}"
      line += " through: :#{reflection.options[:through]}" if reflection.options[:through]
      line += " polymorphic" if reflection.options[:polymorphic]
      line
    end

    def model_path(klass)
      relative = "app/models/#{klass.name.underscore}.rb"
      @root.join(relative).exist? ? relative : nil
    end
  end
end
