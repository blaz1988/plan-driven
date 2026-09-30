# frozen_string_literal: true

require "cgi"

module PlanDriven
  # A plan's statistics as SVG, drawn in Ruby. The same file shows in the wizard, on GitHub next
  # to the delivery report and in its PDF: no JavaScript, nothing to install.
  module Charts
    COLORS = {
      "queued" => "#d1d5db", "agent" => "#3b82f6", "review" => "#f59e0b", "fixes" => "#8b5cf6",
      "merge" => "#10b981", "passed" => "#16a34a", "failed" => "#dc2626", "not run" => "#f59e0b",
      "no scenario" => "#9ca3af"
    }.freeze
    INK = "#1f2330"
    MUTED = "#6b7280"
    GRID = "#eef0f3"
    FONT = "-apple-system, 'Segoe UI', Helvetica, Arial, sans-serif"
    TICKS = [60, 300, 600, 900, 1800, 3600, 7200, 10_800, 21_600, 43_200, 86_400, 172_800, 604_800].freeze
    STATUSES = ["passed", "failed", "not run", "no scenario"].freeze

    # The report's charts by file name, leaving out any the plan has no data for yet.
    def self.report(plan, stats: Statistics.new(plan))
      { "statistics-proof.svg" => proof(Evidence.matrix(plan)), "statistics-burnup.svg" => burnup(stats),
        "statistics-timeline.svg" => timeline(stats), "statistics-time.svg" => breakdown(stats) }.compact
    end

    module_function

    # Criteria merged (blue) and proven by a passing test (green), against the plan's scope.
    def burnup(stats)
      data = stats.burnup or return
      width = 760
      height = 320
      box = { left: 44, right: 24, top: 84, bottom: 36 }
      x = scale_time(data[:from], data[:to], box[:left], width - box[:right])
      top = [data[:scope], 1].max
      y = ->(value) { box[:top] + ((1 - (value.to_f / top)) * (height - box[:top] - box[:bottom])) }
      parts = [heading("Acceptance criteria, merged and proven", "#{data[:scope]} in scope")]
      parts << legend([["Merged", COLORS["agent"]], ["Proven by a passing test", COLORS["passed"]],
                       ["Scope", MUTED]], 20, 70)
      parts << value_grid(top, y, box[:left], width - box[:right])
      parts << time_axis(data[:from], data[:to], x, height - box[:bottom], box[:top])
      parts << (%(<line x1="#{box[:left]}" x2="#{width - box[:right]}" y1="#{f(y[data[:scope]])}" ) +
               %(y2="#{f(y[data[:scope]])}" stroke="#{MUTED}" stroke-width="1.5" stroke-dasharray="5 4"/>))
      parts << step_series(data[:merged], data[:to], x, y, COLORS["agent"], fill: true)
      parts << step_series(data[:proven], data[:to], x, y, COLORS["passed"])
      parts << run_dots(data[:proven].drop(1), x, y)
      svg(width, height, parts.join("\n"), title: "Acceptance criteria merged and proven over time")
    end

    # One row per ticket on a shared clock: queued, agent coding, waiting for review, fixing
    # feedback, approved but not merged.
    def timeline(stats)
      rows = stats.tickets.select { |row| row.segments.any? }
      return if rows.empty?

      from, to = stats.window
      width = 760
      box = { left: 190, right: 100, top: 84, bottom: 36 }
      row_height = 30
      height = box[:top] + (rows.size * row_height) + box[:bottom]
      x = scale_time(from, to, box[:left], width - box[:right])
      phases = Statistics::PHASES.select { |phase, _| rows.any? { |row| row.seconds(phase).positive? } }
      parts = [heading("Where the time went, ticket by ticket", "#{Statistics.duration(to - from)} in development")]
      parts << legend(phases.map { |phase, label| [label, COLORS[phase]] }, 20, 70)
      parts << time_axis(from, to, x, height - box[:bottom], box[:top])
      rows.each_with_index do |row, index|
        parts << ticket_row(row, box[:top] + (index * row_height), x, box[:left])
      end
      svg(width, height, parts.join("\n"), title: "Where the time went, ticket by ticket")
    end

    # How the time tickets were worked on splits between agents and people.
    def breakdown(stats)
      totals = stats.totals.slice(*Statistics::WORK).select { |_, seconds| seconds.positive? }
      sum = totals.values.sum
      return if sum.zero?

      width = 760
      height = 250
      center = [130, 150]
      radius = 72
      circumference = 2 * Math::PI * radius
      offset = 0.0
      rings = totals.map do |phase, seconds|
        length = circumference * seconds / sum
        ring = %(<circle cx="#{center[0]}" cy="#{center[1]}" r="#{radius}" fill="none" stroke="#{COLORS[phase]}" ) +
               %(stroke-width="28" stroke-dasharray="#{f(length)} #{f(circumference - length)}" ) +
               %(stroke-dashoffset="#{f(-offset)}" transform="rotate(-90 #{center[0]} #{center[1]})">) +
               %(<title>#{esc(Statistics::PHASES[phase])}: #{Statistics.duration(seconds)}</title></circle>)
        offset += length
        ring
      end
      share = stats.agent_share
      parts = [heading("Agents and people", "while tickets were being worked on")]
      parts += rings
      parts << (%(<text x="#{center[0]}" y="#{center[1] + 2}" text-anchor="middle" font-size="26" ) +
               %(font-weight="700" fill="#{INK}">#{share}%</text>))
      parts << %(<text x="#{center[0]}" y="#{center[1] + 22}" text-anchor="middle" fill="#{MUTED}">agents</text>)
      totals.each_with_index do |(phase, seconds), index|
        top = 100 + (index * 30)
        percent = (seconds * 100.0 / sum).round
        parts << %(<rect x="260" y="#{top - 11}" width="14" height="14" rx="3" fill="#{COLORS[phase]}"/>)
        parts << %(<text x="284" y="#{top}" fill="#{INK}" font-size="13">#{esc(Statistics::PHASES[phase])}</text>)
        parts << (%(<text x="560" y="#{top}" fill="#{INK}" font-size="13" text-anchor="end" ) +
                 %(font-weight="600">#{Statistics.duration(seconds)}</text>))
        parts << %(<text x="620" y="#{top}" fill="#{MUTED}" font-size="13" text-anchor="end">#{percent}%</text>)
      end
      svg(width, height, parts.join("\n"), title: "Time split between agents and people")
    end

    # Every acceptance criterion's result in one bar.
    def proof(rows)
      return if rows.empty?

      width = 760
      height = 104
      counts = STATUSES.to_h { |status| [status, rows.count { |row| row.status == status }] }
      passed = counts["passed"]
      color = if passed == rows.size then COLORS["passed"]
              elsif counts["failed"].positive? then COLORS["failed"]
              else INK
              end
      parts = [%(<text x="20" y="34" font-size="17" font-weight="700" fill="#{color}">) +
        %(#{passed} of #{rows.size} acceptance criteria proven</text>)]
      left = 20.0
      span = width - 40.0
      parts << %(<clipPath id="proof-bar"><rect x="20" y="48" width="#{span}" height="16" rx="8"/></clipPath>)
      segments = counts.filter_map do |status, count|
        next if count.zero?

        length = span * count / rows.size
        bar = %(<rect x="#{f(left)}" y="48" width="#{f(length)}" height="16" fill="#{COLORS[status]}">) +
              %(<title>#{count} #{status}</title></rect>)
        left += length
        bar
      end
      parts << %(<g clip-path="url(#proof-bar)">#{segments.join}</g>)
      shown = counts.reject { |_, count| count.zero? }
      parts << legend(shown.map { |status, count| ["#{count} #{status}", COLORS[status]] }, 20, 90)
      svg(width, height, parts.join("\n"), title: "#{passed} of #{rows.size} acceptance criteria proven")
    end

    def svg(width, height, body, title:)
      <<~SVG
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 #{width} #{height}" width="#{width}" height="#{height}" role="img" font-family="#{FONT}" font-size="12">
        <title>#{esc(title)}</title>
        <rect width="#{width}" height="#{height}" rx="10" fill="#ffffff"/>
        #{body}
        </svg>
      SVG
    end

    def heading(text, note)
      %(<text x="20" y="28" font-size="15" font-weight="700" fill="#{INK}">#{esc(text)}</text>) +
        %(<text x="20" y="46" fill="#{MUTED}">#{esc(note)}</text>)
    end

    def legend(items, left, top)
      x = left
      items.map do |label, color|
        item = %(<rect x="#{f(x)}" y="#{top - 10}" width="12" height="12" rx="3" fill="#{color}"/>) +
               %(<text x="#{f(x + 18)}" y="#{top}" fill="#{MUTED}">#{esc(label)}</text>)
        x += (label.length * 6.6) + 40
        item
      end.join
    end

    def scale_time(from, to, left, right)
      start = from.to_f
      length = [to.to_f - start, 1].max
      ->(time) { left + ((time.to_f - start) / length * (right - left)) }
    end

    # Round values up the axis: 0, 10, 20, 30, 40 rather than 0, 11, 21, 32, 42.
    def value_grid(top, y, left, right)
      step = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500].find { |size| top / size <= 5 } || (top / 5.0).ceil
      (0..top).step(step).map do |value|
        %(<line x1="#{left}" x2="#{right}" y1="#{f(y[value])}" y2="#{f(y[value])}" stroke="#{GRID}"/>) +
          %(<text x="#{left - 8}" y="#{f(y[value] + 4)}" text-anchor="end" fill="#{MUTED}">#{value}</text>)
      end.join
    end

    # Clock ticks at a round interval, labelled in the plan's own time zone.
    def time_axis(from, to, x, bottom, top)
      length = to.to_f - from.to_f
      step = TICKS.find { |seconds| length / seconds <= 7 } || TICKS.last
      format = step >= 86_400 || length > 86_400 ? "%-d %b" : "%H:%M"
      first = (from.to_f / step).ceil * step
      (first..to.to_f).step(step).map do |seconds|
        time = local(seconds, from)
        %(<line x1="#{f(x[time])}" x2="#{f(x[time])}" y1="#{top}" y2="#{bottom}" stroke="#{GRID}"/>) +
          %(<text x="#{f(x[time])}" y="#{bottom + 18}" text-anchor="middle" fill="#{MUTED}">) +
          %(#{time.strftime(format)}</text>)
      end.join
    end

    # A whole number of seconds as a time in the same zone as `like`, without float drift.
    def local(seconds, like)
      time = Time.at(seconds)
      like.respond_to?(:time_zone) ? time.in_time_zone(like.time_zone) : time.getlocal(like.utc_offset)
    end

    def step_series(points, to, x, y, color, fill: false)
      path = "M#{f(x[points.first.at])},#{f(y[points.first.value])}"
      points.drop(1).each { |point| path << " H#{f(x[point.at])} V#{f(y[point.value])}" }
      path << " H#{f(x[to])}"
      area = ""
      area = %(<path d="#{path} V#{f(y[0])} H#{f(x[points.first.at])} Z" fill="#{color}" fill-opacity=".12"/>) if fill
      %(#{area}<path d="#{path}" fill="none" stroke="#{color}" stroke-width="2.5" stroke-linejoin="round"/>)
    end

    # One dot per evidence run, red when it failed, with the count on the last one.
    def run_dots(points, x, y)
      points.each_with_index.map do |point, index|
        color = point.status == "passed" ? COLORS["passed"] : COLORS["failed"]
        label = if index == points.size - 1
                  %(<text x="#{f(x[point.at] - 8)}" y="#{f(y[point.value] - 10)}" text-anchor="end" ) +
                    %(font-weight="700" fill="#{color}">#{point.value} proven</text>)
                end
        %(<circle cx="#{f(x[point.at])}" cy="#{f(y[point.value])}" r="5" fill="#{color}" stroke="#ffffff" ) +
          %(stroke-width="2"><title>Evidence #{point.status}: #{point.value} proven</title></circle>#{label})
      end.join
    end

    def ticket_row(row, top, x, left)
      ticket = row.ticket
      label = "#{ticket.key}  #{ticket.title.to_s.truncate(24)}"
      bars = row.segments.map do |segment|
        start = x[segment.from]
        length = [x[segment.to] - start, 2].max
        %(<rect x="#{f(start)}" y="#{top + 6}" width="#{f(length)}" height="18" rx="3" ) +
          %(fill="#{COLORS[segment.phase]}">) +
          %(<title>#{esc(ticket.key)} · #{esc(Statistics::PHASES[segment.phase])} · ) +
          %(#{Statistics.duration(segment.seconds)}</title></rect>)
      end
      finish = x[row.segments.last.to]
      total = row.merged? ? Statistics.duration(row.cycle_time) : "open"
      rounds = row.review_rounds.positive? ? " · #{row.review_rounds} fix" : ""
      %(<text x="#{left - 12}" y="#{top + 19}" text-anchor="end" fill="#{INK}">#{esc(label)}</text>) +
        bars.join + %(<text x="#{f(finish + 8)}" y="#{top + 19}" fill="#{MUTED}">#{esc(total + rounds)}</text>)
    end

    def f(number)
      number.to_f.round(1).to_s.delete_suffix(".0")
    end

    def esc(text)
      CGI.escapeHTML(text.to_s)
    end
  end
end
