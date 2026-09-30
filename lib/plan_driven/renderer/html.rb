# frozen_string_literal: true

module PlanDriven
  module Renderer
    # A small Markdown-to-HTML converter for the documents this gem writes: headings, paragraphs,
    # lists, tables, code blocks, emphasis and links. It isn't a general Markdown implementation,
    # and doesn't need to be.
    module HTML
      STYLE = File.read(File.expand_path("style.css", __dir__))
      IMAGE = /\A!\[([^\]]*)\]\(([^)\s]+)\)\z/
      # A table cell that is only a result becomes a coloured pill, and colours its row.
      RESULT = /\A(?:#{Evidence::MARKS.values.map { |mark| Regexp.escape(mark) }.join("|")})?\s*
                (passed|failed|not\ run|no\ scenario|merged)\z/x

      module_function

      def document(markdown, title:, images: {})
        <<~HTML
          <!doctype html>
          <html lang="en">
          <head>
          <meta charset="utf-8">
          <title>#{CGI.escapeHTML(title)}</title>
          <style>#{STYLE}</style>
          </head>
          <body>
          <main>
          #{convert(markdown, images: images)}
          </main>
          </body>
          </html>
        HTML
      end

      def convert(markdown, images: {})
        lines = markdown.to_s.lines.map(&:chomp)
        out = []
        until lines.empty?
          line = lines.first
          if (image = line.strip.match(IMAGE))
            lines.shift
            out << figure(image[1], image[2], images)
          elsif line.start_with?("```")
            out << code_block(lines)
          elsif line.match?(/\A\s*\|/)
            out << table(take_while(lines) { |l| l.match?(/\A\s*\|/) })
          elsif (match = line.match(/\A(\#{1,6})\s+(.*)\z/))
            lines.shift
            level = match[1].size
            out << "<h#{level}>#{inline(match[2])}</h#{level}>"
          elsif line.match?(/\A\s*([-*]|\d+\.)\s+/)
            out << list(take_while(lines) { |l| l.match?(/\A\s*([-*]|\d+\.)\s+/) || l.match?(/\A\s{2,}\S/) })
          elsif line.strip.empty?
            lines.shift
          else
            paragraph = take_while(lines) { |l| !l.strip.empty? && !l.match?(/\A(#|```|\s*\||\s*([-*]|\d+\.)\s)/) }
            paragraph = [lines.shift] if paragraph.empty?
            out << "<p>#{inline(paragraph.join(" "))}</p>"
          end
        end
        out.join("\n")
      end

      def take_while(lines)
        taken = []
        taken << lines.shift while lines.any? && yield(lines.first)
        taken
      end

      def code_block(lines)
        lines.shift
        body = take_while(lines) { |line| !line.start_with?("```") }
        lines.shift
        "<pre><code>#{CGI.escapeHTML(body.join("\n"))}</code></pre>"
      end

      def table(rows)
        cells = rows.map { |row| row.strip.delete_prefix("|").delete_suffix("|").split(/(?<!\\)\|/).map(&:strip) }
        header, *body = cells
        body = body.reject { |row| row.all? { |cell| cell.match?(/\A:?-+:?\z/) } }
        head = header.map { |cell| "<th>#{inline(cell)}</th>" }.join
        rows = body.map { |row| table_row(row) }
        "<table><thead><tr>#{head}</tr></thead><tbody>#{rows.join}</tbody></table>"
      end

      def table_row(row)
        results = row.filter_map { |cell| cell.match(RESULT)&.[](1) }
        cells = row.map do |cell|
          result = cell.match(RESULT)&.[](1)
          content = if result
                      %(<span class="result #{result.tr(" ",
                                                        "-")}">#{result}</span>)
                    else
                      inline(cell.gsub("\\|", "|"))
                    end
          "<td>#{content}</td>"
        end
        klass = results.last ? %( class="#{results.last.tr(" ", "-")}") : ""
        "<tr#{klass}>#{cells.join}</tr>"
      end

      # A chart written next to the document is inlined, so the HTML and PDF stand alone.
      def figure(alt, src, images)
        body = images[src] || %(<img src="#{CGI.escapeHTML(src)}" alt="#{CGI.escapeHTML(alt)}">)
        %(<figure class="chart">#{body}</figure>)
      end

      def list(lines)
        ordered = lines.first.match?(/\A\s*\d+\./)
        items = []
        lines.each do |line|
          if line.match?(/\A\s*([-*]|\d+\.)\s+/)
            items << line.sub(/\A\s*([-*]|\d+\.)\s+/, "")
          else
            items[-1] = "#{items.last} #{line.strip}"
          end
        end
        tag = ordered ? "ol" : "ul"
        "<#{tag}>#{items.map { |item| "<li>#{inline(item)}</li>" }.join}</#{tag}>"
      end

      def inline(text)
        codes = []
        escaped = CGI.escapeHTML(text.to_s).gsub(/`([^`]+)`/) do
          codes << Regexp.last_match(1)
          "\u0000#{codes.size - 1}\u0000"
        end
        escaped = escaped.gsub(/\*\*(.+?)\*\*/, '<strong>\1</strong>')
                         .gsub(/(?<![*\w])\*(?!\s)(.+?)(?<!\s)\*(?![*\w])/, '<em>\1</em>')
                         .gsub(/\[([^\]]+)\]\((https?:[^)\s]+|[^)\s]+\.(?:md|html|pdf))\)/, '<a href="\2">\1</a>')
        escaped.gsub(/\u0000(\d+)\u0000/) { "<code>#{codes[Regexp.last_match(1).to_i]}</code>" }
      end
    end
  end
end
