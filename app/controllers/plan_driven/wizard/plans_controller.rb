# frozen_string_literal: true

require "tempfile"

module PlanDriven
  module Wizard
    # Every form posts here, and every post becomes one `plan-driven` command. The pages only read.
    class PlansController < ApplicationController
      before_action :find_plan, only: %i[show statistics run file]

      def index
        @plans = Plan.order(id: :desc)
      end

      def new
        @template = PlanDriven.configuration.template
      end

      def create
        @template = PlanDriven.configuration.template
        answers = interview_answers
        missing = @template.asked.select { |section| section.required && answers[section.key].to_s.strip.empty? }
        return missing_answers(missing) if missing.any?

        job = start(Commands.argv("new", title: params[:title]), stdin: interview_input(answers))
        redirect_to root_path(job: job.id)
      rescue ArgumentError => e
        redirect_to new_plan_path, alert: e.message
      end

      def show
        @step = params[:step].presence || Steps.current(@plan)
        @template = PlanDriven.configuration.template
      end

      def statistics
        @step = "statistics"
        @stats = Statistics.new(@plan)
      end

      def run
        job = start(Commands.argv(params[:do], command_fields))
        redirect_to after_run(job)
      rescue ArgumentError => e
        redirect_to plan_path(@plan.key, params[:step].presence.presence_in(Steps.keys)), alert: e.message
      end

      def run_global
        job = start(Commands.argv(params[:do], {}))
        redirect_to root_path(job: job.id)
      rescue ArgumentError => e
        redirect_to root_path, alert: e.message
      end

      def actor
        session[:plan_driven_actor] = params[:actor].to_s.strip.presence
        redirect_back fallback_location: root_path
      end

      def file
        path = Renderer.directory(@plan).join(params[:name])
        return head(:not_found) unless path.file?

        send_file path, disposition: "inline"
      end

      private

      def after_run(job)
        return plan_statistics_path(@plan.key, job: job.id) if params[:step] == "statistics"

        plan_path(@plan.key, params[:step].presence, job: job.id, open: params[:open].presence,
                                                     anchor: params[:open].presence)
      end

      def find_plan
        @plan = Plan.find_by_reference!(params[:key])
      rescue ActiveRecord::RecordNotFound => e
        redirect_to root_path, alert: e.message
      end

      def command_fields
        fields = params.permit(:section, :instruction, :role, :note, :ticket, :feedback, :text, tickets: []).to_h
        fields[:plan] = @plan.key
        text = fields.delete("text")
        fields[:file] = section_file(text) if params[:do] == "edit"
        fields
      end

      def interview_answers
        params.fetch(:answers, {}).permit(*@template.asked.map(&:key)).to_h
      end

      def missing_answers(missing)
        flash.now[:alert] = "#{missing.map(&:title).join(", ")} #{missing.one? ? "is" : "are"} required."
        render(:new, status: :unprocessable_entity)
      end

      def interview_input(answers)
        Commands.interview_input(@template, answers)
      end

      # `edit --from` reads the new text from a file; it stays in tmp/ so the command can be rerun.
      def section_file(text)
        dir = Job.dir.join("sections")
        FileUtils.mkdir_p(dir)
        path = dir.join("#{@plan.key}-#{params[:section]}-#{SecureRandom.hex(4)}.md")
        File.write(path, text.to_s.gsub("\r\n", "\n"))
        path.relative_path_from(PlanDriven.configuration.root_path).to_s
      end
    end
  end
end
