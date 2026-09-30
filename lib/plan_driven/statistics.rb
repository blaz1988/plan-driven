# frozen_string_literal: true

module PlanDriven
  # Where a plan's time went, read from its audit trail: when each ticket was queued, when an
  # agent was writing code, when it waited for a person, and when its acceptance criteria were
  # merged and then proven. Arithmetic on recorded events, so it gives the same answer every time.
  class Statistics
    PHASES = {
      "queued" => "Queued",
      "agent" => "Agent coding",
      "review" => "Waiting for review",
      "fixes" => "Agent fixing feedback",
      "merge" => "Approved, not merged"
    }.freeze
    WORK = %w[agent review fixes merge].freeze
    AGENT = %w[agent fixes].freeze

    # Each of these events starts the ticket's next phase; merging ends the last one.
    NEXT_PHASE = {
      "ticket.agent_started" => "agent", "ticket.pr_opened" => "review", "ticket.agent_failed" => "review",
      "ticket.changes_requested" => "fixes", "ticket.pr_approved" => "merge", "ticket.merged" => nil
    }.freeze

    Segment = Struct.new(:phase, :from, :to) do
      def seconds = to - from
    end

    TicketRow = Struct.new(:ticket, :segments, :review_rounds, :merged_at, keyword_init: true) do
      def seconds(phase = nil)
        segments.select { |segment| phase.nil? || segment.phase == phase }.sum(&:seconds)
      end

      def merged? = !merged_at.nil?
      def first_time? = merged? && review_rounds.zero?
      def started_at = segments.find { |segment| segment.phase != "queued" }&.from
      def cycle_time = merged_at && started_at && (merged_at - started_at)
    end

    Point = Struct.new(:at, :value, :status)

    attr_reader :plan, :now

    def self.duration(seconds)
      return "-" if seconds.nil?

      seconds = seconds.round
      return "#{seconds}s" if seconds < 60

      minutes = seconds / 60
      return "#{minutes} min" if minutes < 60

      hours, minutes = minutes.divmod(60)
      return "#{hours} h#{" #{minutes} min" if minutes.positive?}" if hours < 24

      days, hours = hours.divmod(24)
      "#{days} d#{" #{hours} h" if hours.positive?}"
    end

    def initialize(plan, now: Time.now)
      @plan = plan
      @now = now
      @events = plan.events.includes(:ticket).to_a
    end

    def started? = !development_start.nil?

    def development_start
      @development_start ||= (first("tickets.approved") || first("ticket.agent_started"))&.created_at
    end

    def delivered_at
      first("plan.delivered")&.created_at
    end

    # The span the charts draw: from approving the tickets to delivery, or to now while it runs.
    def window
      return unless started?

      finish = [delivered_at || now, *plan.evidence_runs.map(&:created_at)].max
      [development_start, [finish, development_start + 60].max]
    end

    def tickets
      @tickets ||= plan.tickets.map { |ticket| ticket_row(ticket) }
    end

    def totals
      PHASES.keys.to_h { |phase| [phase, tickets.sum { |row| row.seconds(phase) }] }
    end

    def work_seconds
      totals.slice(*WORK).values.sum
    end

    # The agents' part of the time a ticket was being worked on, from 0 to 100.
    def agent_share
      work = work_seconds
      return if work.zero?

      (totals.slice(*AGENT).values.sum * 100.0 / work).round
    end

    # Planning phases, first to last, as [label, seconds].
    def phases
      drafted = first("plan.drafted")&.created_at
      approved = last("plan.approved")&.created_at
      proven = plan.evidence_runs.find(&:passed?)&.created_at
      [["Planning", span(drafted, approved)], ["Tickets", span(approved, development_start)],
       ["Development", span(development_start, delivered_at || (now if started?))],
       ["Proof", span(delivered_at, proven)]]
    end

    # Criteria merged and criteria proven by a passing test, over time, against the plan's scope.
    def burnup
      return unless started?

      { scope: plan.tickets.sum { |ticket| ticket.criteria.size }, from: window.first, to: window.last,
        merged: merged_points, proven: proven_points }
    end

    def summary
      rows = tickets
      { lead_time: span(first("plan.drafted")&.created_at, delivered_at || now), development: phases[2].last,
        merged: rows.count(&:merged?), tickets: rows.size, first_time: rows.count(&:first_time?),
        review_rounds: rows.sum(&:review_rounds), agent_share: agent_share,
        points: plan.tickets.sum { |ticket| ticket.estimate.to_i } }.merge(proof, usage)
    end

    private

    def proof
      matrix = Evidence.matrix(plan)
      { proven: matrix.count { |row| row.status == "passed" }, criteria: matrix.size,
        evidence: plan.evidence_runs.any? }
    end

    def usage
      totals = Usage.totals(Usage.rows(plan))
      { tokens: totals[:total_tokens], cost: totals[:cost] }
    end

    def ticket_row(ticket)
      events = @events.select { |event| event.ticket_id == ticket.id && NEXT_PHASE.key?(event.name) }
      TicketRow.new(ticket: ticket, segments: segments(events),
                    review_rounds: events.count { |event| event.name == "ticket.changes_requested" },
                    merged_at: events.reverse.find { |event| event.name == "ticket.merged" }&.created_at)
    end

    # Every ticket is queued from the moment the tickets are approved until its agent starts.
    def segments(events)
      return [] unless development_start

      phase = "queued"
      from = development_start
      list = events.filter_map do |event|
        segment = Segment.new(phase, from, event.created_at) if phase && event.created_at > from
        phase = NEXT_PHASE[event.name]
        from = [from, event.created_at].max
        segment
      end
      finish = delivered_at || now
      list << Segment.new(phase, from, finish) if phase && finish > from
      list
    end

    def merged_points
      seen = Set.new
      count = 0
      merges = @events.select { |event| event.name == "ticket.merged" && event.ticket && seen.add?(event.ticket_id) }
      [Point.new(development_start, 0)] + merges.map do |event|
        count += event.ticket.criteria.size
        Point.new(event.created_at, count)
      end
    end

    def proven_points
      runs = plan.evidence_runs.to_a
      [Point.new(development_start, 0)] + runs.map do |run|
        Point.new(run.created_at, Evidence.matrix(plan, run).count { |row| row.status == "passed" }, run.status)
      end
    end

    def first(name)
      @events.find { |event| event.name == name }
    end

    def last(name)
      @events.reverse.find { |event| event.name == name }
    end

    def span(from, to)
      from && to && to >= from ? to - from : nil
    end
  end
end
