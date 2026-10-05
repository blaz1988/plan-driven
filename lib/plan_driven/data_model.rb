# frozen_string_literal: true

require "cgi"
require "fileutils"

module PlanDriven
  # The tables a plan changes, before and after, drawn as one SVG. It's read from the migration
  # code in the Database changes section and laid over the real schema, so nothing in it is made
  # up by the model: a change described only in prose isn't drawn.
  class DataModel
    FILE = "data-model.svg"
    Column = Struct.new(:name, :type, :status, :was, keyword_init: true)
    Table = Struct.new(:name, :status, :columns, :was, keyword_init: true) do
      def column(name)
        columns.find { |column| column.name == name }
      end

      def subject?
        status != :context
      end
    end

    NAME = /[:"']?([a-z_][a-z0-9_]*)["']?/
    TABLE_BLOCK = /\A(\s*)(create_table|change_table)\s*\(?\s*#{NAME}(.*)/
    TOP_LEVEL = /\A\s*(add_column|add_reference|add_belongs_to|add_timestamps|remove_column|remove_columns|
                 remove_reference|remove_belongs_to|remove_timestamps|rename_column|change_column|
                 change_column_null|change_column_default|drop_table|rename_table)\b\s*\(?\s*#{NAME}(.*)/x
    BLOCK_COLUMN = /\A\s*t\.(\w+)\b\s*\(?\s*(.*)/
    TIMESTAMPS = %w[created_at updated_at].freeze
    TYPES = %w[string text integer bigint float decimal numeric boolean date datetime time timestamp binary json
               jsonb uuid citext inet enum virtual].freeze

    # Writes the diagram beside the plan and returns its path, or removes an old one when there's
    # nothing to draw.
    def self.write(plan, dir, schema:, config: PlanDriven.configuration)
      path = Pathname(dir).join(FILE)
      model = new(plan.section("database_changes"), schema: schema) if config.data_model_diagram
      if model&.drawable?
        File.write(path, model.to_svg)
        path
      else
        FileUtils.rm_f(path)
        nil
      end
    end

    def initialize(text, schema:)
      @text = text.to_s
      @schema = schema
    end

    def drawable?
      subjects.any?
    end

    # Whether the section has migration code to draw from at all.
    def code?
      changes.any?
    end

    def tables
      @tables ||= build
    end

    def subjects
      tables.select(&:subject?)
    end

    # [table, column, referenced table] for every foreign key between the tables drawn.
    def links
      names = tables.map(&:name)
      subjects.flat_map do |table|
        table.columns.filter_map do |column|
          target = reference_target(table.name, column.name)
          [table.name, column.name, target] if target && target != table.name && names.include?(target)
        end
      end
    end

    def to_svg
      Drawing.new(self).to_svg
    end

    private

    def build
      by_name = {}
      changes.each { |change| apply(by_name, change) }
      subjects = by_name.values
      context = subjects.flat_map do |table|
        table.columns.filter_map { |column| reference_target(table.name, column.name) if column.status != :kept }
      end.uniq - by_name.keys
      context.select { |name| @schema.table?(name) }.each do |name|
        by_name[name] = Table.new(name: name, status: :context, columns: existing_columns(name))
      end
      by_name.values
    end

    def apply(by_name, change)
      kind, table_name, rest = change
      table = (by_name[table_name] ||= start(table_name, kind))
      case kind
      when :create
        add(table, "id", rest[/id:\s*:(\w+)/, 1] || "bigint") unless rest.match?(/id:\s*false/)
      when :drop then table.status = :removed
      when :rename_table
        target = symbols(rest).first or return
        by_name.delete(table_name)
        by_name[target] = table.tap do |t|
          t.was = table_name
          t.name = target
        end
      else column_change(table, kind, rest)
      end
    end

    def start(name, kind)
      if kind == :create
        Table.new(name: name, status: :new, columns: [])
      else
        Table.new(name: name, status: @schema.table?(name) ? :changed : :new, columns: existing_columns(name))
      end
    end

    def column_change(table, kind, rest)
      args = symbols(rest)
      case kind
      when :add then add(table, args[0], args[1] || "string")
      when :reference then reference(table, args[0], rest)
      when :timestamps then TIMESTAMPS.each { |name| add(table, name, "datetime") }
      when :rename then rename(table, args[0], args[1])
      when :change then mark(table, args[0], :changed, type: args[1])
      else removal(table, kind, args, rest)
      end
    end

    def removal(table, kind, args, rest)
      names = case kind
              when :remove then args
              when :remove_reference then ["#{args[0]}_id", ("#{args[0]}_type" if rest.include?("polymorphic"))]
              when :remove_timestamps then TIMESTAMPS
              else []
              end
      names.compact.each { |name| mark(table, name, :removed) }
    end

    def add(table, name, type)
      return unless name

      # Already in the schema once the plan's migration has run; it's still what the plan adds.
      if (column = table.column(name))
        column.status = :added
        return
      end
      table.columns << Column.new(name: name, type: type, status: :added)
    end

    def reference(table, name, rest)
      return unless name

      add(table, "#{name}_id", rest.match?(/type:\s*:uuid/) ? "uuid" : "bigint")
      add(table, "#{name}_type", "string") if rest.include?("polymorphic")
      target = rest[/to_table:\s*#{NAME}/o, 1]
      @explicit_targets ||= {}
      @explicit_targets[[table.name, "#{name}_id"]] = target if target
    end

    def mark(table, name, status, type: nil)
      return unless name

      column = table.column(name) || Column.new(name: name, type: type || "?", status: status).tap do |c|
        table.columns << c
      end
      return if column.status == :added

      column.status = status
      column.type = type if type
    end

    def rename(table, from, to)
      return unless from && to

      column = table.column(from) || Column.new(name: from, type: "?").tap { |c| table.columns << c }
      column.was = from
      column.name = to
      column.status = :renamed unless column.status == :added
    end

    def existing_columns(name)
      return [] unless @schema.table?(name)

      @schema.columns(name).map { |column_name, type, *| Column.new(name: column_name, type: type, status: :kept) }
    end

    def reference_target(table, column)
      explicit = @explicit_targets&.dig([table, column])
      return explicit if explicit
      return unless column.end_with?("_id") && column != "id"

      base = column.delete_suffix("_id")
      [base.pluralize, base].find { |name| tables_known.include?(name) || @schema.table?(name) }
    end

    def tables_known
      @tables_known ||= changes.map { |_, table, _| table }
    end

    # [kind, table, the rest of the line] for each migration statement in the section's Ruby code.
    def changes
      @changes ||= begin
        block = nil
        code_lines.each_with_object([]) do |line, found|
          if block
            if line.match?(/\A#{block[:indent]}end\b/)
              block = nil
            elsif (match = line.match(BLOCK_COLUMN))
              block_change(found, block[:table], match[1], match[2])
            end
          elsif (match = line.match(TABLE_BLOCK))
            block = { indent: match[1], table: match[3] } if line.match?(/\bdo\b/)
            found << [match[2] == "create_table" ? :create : :touch, match[3], match[4]]
          elsif (match = line.match(TOP_LEVEL))
            top_level_change(found, match[1], match[2], match[3])
          end
        end
      end
    end

    def block_change(found, table, method, rest)
      case method
      when "references", "belongs_to" then found << [:reference, table, rest]
      when "timestamps" then found << [:timestamps, table, rest]
      when "column" then found << [:add, table, rest]
      when "remove" then found << [:remove, table, rest]
      when "remove_references", "remove_belongs_to" then found << [:remove_reference, table, rest]
      when "rename" then found << [:rename, table, rest]
      when "change" then found << [:change, table, rest]
      when *TYPES then symbols(rest).each { |name| found << [:add, table, ":#{name}, :#{method}"] }
      end
    end

    def top_level_change(found, method, table, rest)
      kind = { "add_column" => :add, "add_reference" => :reference, "add_belongs_to" => :reference,
               "add_timestamps" => :timestamps, "remove_column" => :remove, "remove_columns" => :remove,
               "remove_reference" => :remove_reference, "remove_belongs_to" => :remove_reference,
               "remove_timestamps" => :remove_timestamps, "rename_column" => :rename, "change_column" => :change,
               "change_column_null" => :change, "change_column_default" => :change, "drop_table" => :drop,
               "rename_table" => :rename_table }.fetch(method)
      rest = symbols(rest).first.then { |name| name ? ":#{name}" : "" } if method.start_with?("change_column_")
      found << [kind, table, rest]
    end

    # The leading symbol or string arguments, before any keyword options.
    def symbols(rest)
      rest.to_s.split(/,\s*(?=\w+:\s)/).first.to_s.scan(/(?<![\w:]):([a-z_][a-z0-9_]*)\b|["']([a-z_][a-z0-9_]*)["']/)
          .map(&:compact).map(&:first)
    end

    def code_lines
      fenced = false
      ruby = false
      @text.each_line.with_object([]) do |line, lines|
        if line.start_with?("```")
          ruby = !fenced && line.match?(/\A```\s*(ruby|rb)?\s*\z/i)
          fenced = !fenced
        elsif fenced && ruby
          lines << line.chomp
        end
      end
    end
  end
end

require_relative "data_model/drawing"
