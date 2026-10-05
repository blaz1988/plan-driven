# frozen_string_literal: true

module PlanDriven
  class DataModel
    # The SVG: changed and new tables on top, the tables they reference below, a line from each
    # foreign key to its table.
    class Drawing
      COLORS = { new: "#16a34a", added: "#16a34a", changed: "#d97706", renamed: "#d97706", removed: "#dc2626",
                 context: "#9ca3af", kept: Charts::INK }.freeze
      FILLS = { new: "#ecfdf5", changed: "#fffbeb", removed: "#fef2f2", context: "#f9fafb" }.freeze
      MARKS = { added: "+", changed: "~", renamed: "~", removed: "−" }.freeze
      LABELS = { new: "new", changed: "changed", removed: "removed", context: "unchanged" }.freeze
      LINK = "#6b7280"
      MONO = "ui-monospace, SFMono-Regular, Menlo, monospace"
      ARROW = "<defs><marker id=\"dm-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" " \
              "markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" " \
              "fill=\"#{LINK}\"/></marker></defs>".freeze
      WIDTH = 260
      GAP = 48
      ROW = 20
      HEADER = 32
      PER_ROW = 3
      SHOWN = 10

      def initialize(model)
        @model = model
      end

      def to_svg
        rows = [@model.subjects, @model.tables.reject(&:subject?)].reject(&:empty?).flat_map do |row|
          row.each_slice(PER_ROW).to_a
        end
        width = [rows.map { |row| (row.size * WIDTH) + ((row.size + 1) * GAP) }.max, 620].max
        boxes = layout(rows, width)
        height = boxes.values.map { |box| box[:y] + box[:height] }.max + 30
        Charts.svg(width, height, body(boxes), title: "Data model: what this plan changes")
      end

      private

      def body(boxes)
        parts = [Charts.heading("Data model", summary), Charts.legend(legend, 20, 70), ARROW]
        @model.links.each { |from, column, to| parts << link(boxes[from], column, boxes[to]) }
        boxes.each_value { |box| parts << table(box) }
        parts.join("\n")
      end

      def summary
        counts = @model.subjects.group_by(&:status).transform_values(&:size)
        tables = %i[new changed removed].filter_map { |status| "#{counts[status]} #{status}" if counts[status] }
        "Tables this plan changes: #{tables.join(", ")}. Read from the migration code in Database changes."
      end

      def legend
        [["New", COLORS[:new]], ["Changed", COLORS[:changed]], ["Removed", COLORS[:removed]],
         ["Referenced, unchanged", COLORS[:context]]]
      end

      def layout(rows, width)
        y = 96
        rows.each_with_object({}) do |row, boxes|
          heights = row.map { |table| HEADER + (visible(table).size * ROW) + 12 }
          left = (width - ((row.size * WIDTH) + ((row.size - 1) * GAP))) / 2
          row.each_with_index do |table, index|
            boxes[table.name] = { table: table, x: left + (index * (WIDTH + GAP)), y: y, height: heights[index] }
          end
          y += heights.max + GAP + 12
        end
      end

      # [column or a "N more columns" line] to draw. A referenced table shows only its key; a big
      # table shows what changes, its keys, and a count of the rest.
      def visible(table)
        columns = table.columns
        keep = if table.status == :context
                 columns.select { |column| column.name == "id" }
               elsif columns.size > SHOWN
                 columns.select { |column| column.status != :kept || column.name.match?(/\A(id|\w+_id)\z/) }
               else
                 columns
               end
        hidden = columns.size - keep.size
        hidden.positive? ? keep + ["#{hidden} more column#{"s" unless hidden == 1}"] : keep
      end

      def table(box)
        table = box[:table]
        x = box[:x]
        y = box[:y]
        rows = visible(table).each_with_index.map do |column, index|
          column_row(column, x, y + HEADER + 18 + (index * ROW))
        end
        [frame(box, COLORS[table.status], table.subject? ? 2 : 1.2, FILLS[table.status]), title(table, x, y),
         *rows].join("\n")
      end

      def title(table, x, y)
        name = table.was ? "#{table.was} → #{table.name}" : table.name
        text(x + 12, y + 21, name, size: 13, weight: 600, decoration: table.status == :removed) +
          text(x + WIDTH - 12, y + 21, LABELS[table.status], size: 11, color: COLORS[table.status], anchor: "end")
      end

      def frame(box, color, stroke, fill)
        x = box[:x]
        y = box[:y]
        header = "M#{x} #{y + HEADER}V#{y + 8}a8 8 0 0 1 8 -8H#{x + WIDTH - 8}a8 8 0 0 1 8 8V#{y + HEADER}Z"
        %(<rect x="#{x}" y="#{y}" width="#{WIDTH}" height="#{box[:height]}" rx="8" fill="#ffffff" ) +
          %(stroke="#{color}" stroke-width="#{stroke}"/>) +
          %(<path d="#{header}" fill="#{fill}" stroke="#{color}" stroke-width="#{stroke}"/>)
      end

      def column_row(column, x, y)
        return text(x + 26, y, column, size: 11, color: Charts::MUTED, italic: true) if column.is_a?(String)

        color = COLORS[column.status]
        name = column.was && column.was != column.name ? "#{column.was} → #{column.name}" : column.name
        [text(x + 12, y, MARKS[column.status].to_s, size: 12, color: color, weight: 700),
         text(x + 26, y, name, size: 12, color: color, mono: true, decoration: column.status == :removed),
         text(x + WIDTH - 12, y, column.type.to_s, size: 11, color: Charts::MUTED, anchor: "end")].join
      end

      def link(from, column, to)
        index = visible(from[:table]).index { |c| c.is_a?(Column) && c.name == column }
        return "" unless index && to

        style = if from[:table].column(column).status == :removed
                  %(stroke="#{COLORS[:removed]}" stroke-dasharray="5 4")
                else
                  %(stroke="#{LINK}")
                end
        path = curve(from, from[:y] + HEADER + 14 + (index * ROW), to)
        label = Charts.esc("#{from[:table].name}.#{column} → #{to[:table].name}")
        "<path d=\"#{path}\" fill=\"none\" #{style} stroke-width=\"1.4\" marker-end=\"url(#dm-arrow)\">" \
          "<title>#{label}</title></path>"
      end

      # From the side of the foreign key's row to the top of a table below, or to the side of one
      # in the same row.
      def curve(from, start_y, to)
        right = to[:x] > from[:x]
        start_x = right ? from[:x] + WIDTH : from[:x]
        bend = right ? 40 : -40
        if to[:y] >= from[:y] + from[:height]
          end_x = to[:x] + (WIDTH / 2)
          return "M#{start_x} #{start_y}C#{start_x + bend} #{start_y} #{end_x} #{to[:y] - 50} #{end_x} #{to[:y]}"
        end

        end_x = right ? to[:x] : to[:x] + WIDTH
        end_y = to[:y] + (HEADER / 2)
        "M#{start_x} #{start_y}C#{start_x + bend} #{start_y} #{end_x - bend} #{end_y} #{end_x} #{end_y}"
      end

      def text(x, y, value, size:, color: Charts::INK, weight: 400, anchor: "start", **style)
        extra = +""
        extra << ' font-style="italic"' if style[:italic]
        extra << ' text-decoration="line-through"' if style[:decoration]
        %(<text x="#{x}" y="#{y}" font-family="#{style[:mono] ? MONO : Charts::FONT}" font-size="#{size}" ) +
          %(font-weight="#{weight}" fill="#{color}" text-anchor="#{anchor}"#{extra}>#{Charts.esc(value)}</text>)
      end
    end
  end
end
