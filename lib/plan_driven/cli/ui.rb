# frozen_string_literal: true

require "io/console"

module PlanDriven
  class CLI
    # Terminal output and input. Colour only when writing to a terminal.
    class UI
      COLORS = { red: 31, green: 32, yellow: 33, blue: 34, magenta: 35, cyan: 36, gray: 90, bold: 1 }.freeze

      attr_reader :input, :output

      def initialize(input: $stdin, output: $stdout, assume_yes: false)
        @input = input
        @output = output
        @assume_yes = assume_yes
      end

      def say(text = "")
        output.puts(text)
      end

      def paint(text, color)
        return text unless output.respond_to?(:tty?) && output.tty? && ENV["NO_COLOR"].nil?

        "\e[#{COLORS.fetch(color)}m#{text}\e[0m"
      end

      def heading(text)
        say
        say paint(text, :bold)
      end

      def success(text) = say(paint("✓ #{text}", :green))
      def warn(text) = say(paint("! #{text}", :yellow))
      def error(text) = say(paint("✗ #{text}", :red))
      def muted(text) = say(paint(text, :gray))

      def ask(prompt, default: nil)
        output.print(default ? "#{prompt} [#{default}] " : "#{prompt} ")
        answer = read_line.strip
        answer.empty? ? default.to_s : answer
      end

      # Several lines, finished by an empty line. Piped answers (from the wizard, or a script) are
      # echoed, so the transcript reads like a typed interview.
      def ask_multiline(prompt)
        say paint(prompt, :cyan)
        muted "  (finish with an empty line)"
        lines = []
        loop do
          output.print "  > "
          line = read_line(nil)
          output.puts(line.to_s.rstrip) if piped?
          break if line.nil? || line.strip.empty?

          lines << line.rstrip
        end
        lines.join("\n")
      end

      def secret(prompt)
        output.print "#{prompt} "
        value = input.respond_to?(:noecho) && input.tty? ? PlanDriven.utf8(input.noecho(&:gets)) : read_line
        output.puts
        value.to_s.strip
      end

      def confirm?(prompt)
        return true if @assume_yes

        ask("#{prompt} [y/N]").match?(/\Ay(es)?\z/i)
      end

      def confirm_word?(prompt, word)
        return true if @assume_yes

        ask("#{prompt} Type #{paint(word, :bold)} to continue:") == word
      end

      def report(report, ok_message: "All checks passed")
        report.fixes.each { |fix| muted "  fixed: #{fix}" }
        report.errors.each { |message| error message }
        report.warnings.each { |message| warn message }
        success ok_message if report.errors.empty? && report.warnings.empty?
      end

      # On a terminal, the last column is cut to fit its width, so rows don't wrap.
      def table(headers, rows)
        rows = fit_last_column(headers, rows)
        widths = headers.each_index.map { |i| ([headers[i]] + rows.map { |row| row[i] }).map { |v| v.to_s.length }.max }
        line = ->(cells) { cells.each_with_index.map { |cell, i| cell.to_s.ljust(widths[i]) }.join("  ") }
        say paint(line.call(headers), :bold)
        rows.each { |row| say line.call(row) }
      end

      private

      def fit_last_column(headers, rows)
        columns = terminal_width or return rows
        widths = headers[0..-2].each_index.map do |i|
          ([headers[i]] + rows.map do |row|
            row[i]
          end).map { |v| v.to_s.length }.max
        end
        room = columns - widths.sum - (2 * widths.size) - 1
        return rows if room < 20

        rows.map { |row| row[0..-2] + [row.last.to_s.truncate(room)] }
      end

      def terminal_width
        return unless output.respond_to?(:tty?) && output.tty? && output.respond_to?(:winsize)

        output.winsize[1].then { |columns| columns.positive? ? columns : nil }
      rescue StandardError
        nil
      end

      def piped?
        !(input.respond_to?(:tty?) && input.tty?)
      end

      def read_line(at_end = "")
        line = input.gets
        line.nil? ? at_end : PlanDriven.utf8(line)
      end
    end
  end
end
