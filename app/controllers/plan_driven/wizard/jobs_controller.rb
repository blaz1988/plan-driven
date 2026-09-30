# frozen_string_literal: true

module PlanDriven
  module Wizard
    # Polled by the terminal panel while a command runs.
    class JobsController < ApplicationController
      def show
        data = Job.find(params[:id]).to_h
        data["plan"] = data["output"][/✓ (PD-\d+) drafted/, 1]
        render json: data
      rescue ArgumentError => e
        render json: { error: e.message }, status: :not_found
      end
    end
  end
end
