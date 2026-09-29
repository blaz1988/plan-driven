# frozen_string_literal: true

module PlanDriven
  class CLI
    # Writing, checking and approving the plan.
    module PlanCommands
      def cmd_new(*words)
        title = words.join(" ").strip
        title = ui.ask("Title of the change:") if title.empty?
        raise ArgumentError, "A plan needs a title." if title.empty?

        ui.heading "Plan: #{title}"
        ui.muted "A few questions first. The rest of the plan is drafted from your answers and the schema."
        answers = interview
        ui.say
        ui.say "Drafting with #{LLM.new.label}..."
        plan, result = delivery.create_plan(title: title, answers: answers)
        ui.success "#{plan.key} drafted (#{result.attempts} attempt#{"s" unless result.attempts == 1})"
        result.assumptions.each { |assumption| ui.muted "  assumed: #{assumption}" }
        ui.report(result.report)
        show_paths(Renderer.write_plan(plan).values)
        next_step(plan, result.report)
      end

      def cmd_list
        plans = Plan.order(:id)
        return ui.say("No plans yet. Start one with `plan-driven new \"Title\"`.") if plans.empty?

        ui.table(%w[Plan Title Phase Tickets Revision], plans.map do |plan|
          [plan.key, plan.title.truncate(50), plan.status.tr("_", " "), plan.tickets.size, plan.revision]
        end)
      end

      def cmd_show(reference = nil)
        plan = find_plan(reference)
        if @options[:section]
          ui.say plan.section(@options[:section])
        else
          ui.say Renderer::Markdown.plan(plan)
        end
      end

      def cmd_edit(reference = nil, key = nil)
        plan = find_plan(reference)
        section = PlanDriven.configuration.template[key] or
          raise ArgumentError, "Which section? One of: #{PlanDriven.configuration.template.keys.join(", ")}"
        text = edit_in_editor(plan.section(section.key), "#{plan.key}-#{section.key}")
        return ui.muted("No change.") if text.strip == plan.section(section.key).strip

        delivery.edit_section(plan, section.key, text)
        ui.success "#{section.title} updated; #{plan.key} is now revision #{plan.revision} (#{plan.status})"
        ui.report(Guards::Report.from_h(plan.guard_report))
      end

      def cmd_redraft(reference = nil, key = nil, *instruction)
        plan = find_plan(reference)
        if instruction.empty?
          raise ArgumentError,
                "Say what to change, for example: redraft PD-1 testing \"add permission cases\""
        end

        ui.say "Redrafting #{key}..."
        ui.say delivery.redraft_section(plan, key, instruction.join(" "))
        ui.report(Guards::Report.from_h(plan.reload.guard_report))
      end

      def cmd_check(reference = nil)
        plan = find_plan(reference)
        report = delivery.check_plan(plan)
        ui.report(report)
        next_step(plan, report)
      end

      def cmd_submit(reference = nil)
        plan = find_plan(reference)
        delivery.submit(plan)
        ui.success "#{plan.key} revision #{plan.revision} is in review"
        ui.say "Approvals needed: #{plan.missing_approvals.join(", ")}. `plan-driven approve #{plan.key} --as ROLE`"
      end

      def cmd_approve(reference = nil)
        plan = find_plan(reference)
        role = @options[:role] || PlanDriven.configuration.plan_approvals.first
        missing = delivery.approve_plan(plan, role: role, note: @options[:note])
        ui.success "#{plan.key} approved as #{role} by #{delivery.actor}"
        if missing.empty?
          ui.success "Every approval is in. #{plan.key} is approved; " \
                     "`plan-driven tickets #{plan.key}` drafts the tickets."
        else
          ui.say "Still needed: #{missing.join(", ")}"
        end
      end

      def cmd_reject(reference = nil)
        plan = find_plan(reference)
        raise ArgumentError, "Say what needs to change with --note." if @options[:note].to_s.empty?

        role = @options[:role] || PlanDriven.configuration.plan_approvals.first
        delivery.reject_plan(plan, role: role, note: @options[:note])
        ui.warn "#{plan.key} sent back to draft: #{@options[:note]}"
      end

      def cmd_pdf(reference = nil)
        plan = find_plan(reference)
        paths = Renderer.write_plan(plan)
        ui.success "#{plan.key} written"
        show_paths(paths.values)
        return if paths[:pdf]

        ui.warn "No Chrome or Chromium found, so no PDF; set config.pdf_renderer to use another tool."
      end

      def cmd_log(reference = nil)
        plan = find_plan(reference)
        ui.table(%w[When Event Ticket By Details], plan.events.map do |event|
          [event.created_at.strftime("%Y-%m-%d %H:%M"), event.name, event.ticket&.key.to_s, event.actor,
           event.payload.to_h.map { |k, v| "#{k}=#{Array(v).join(",")}" }.join(" ").truncate(60)]
        end)
      end

      private

      def interview
        PlanDriven.configuration.template.asked.to_h do |section|
          answer = ""
          loop do
            answer = ui.ask_multiline("#{section.title}: #{section.question}")
            break unless section.required && answer.strip.empty?

            ui.warn "#{section.title} is required."
          end
          [section.key, answer]
        end
      end

      def next_step(plan, report)
        if report.ok?
          ui.say "Next: read #{plan.key} (`plan-driven show #{plan.key}` or the PDF), " \
                 "then `plan-driven submit #{plan.key}`."
        else
          ui.say "Fix the errors with `plan-driven edit #{plan.key} SECTION` or `plan-driven redraft #{plan.key} " \
                 "SECTION \"instruction\"`, then `plan-driven check #{plan.key}`."
        end
      end

      def edit_in_editor(text, name)
        editor = ENV["VISUAL"].presence || ENV["EDITOR"].presence or
          raise ConfigurationError, "Set $EDITOR (for example `export EDITOR=\"code --wait\"`) to edit sections."
        Tempfile.create([name, ".md"]) do |file|
          file.write(text)
          file.flush
          system("#{editor} #{file.path}") or raise Error, "The editor exited with an error; nothing changed."
          File.read(file.path)
        end
      end
    end
  end
end
