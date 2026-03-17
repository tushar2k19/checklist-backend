# frozen_string_literal: true

module Api
  class TokenUsageAnalyticsController < ApplicationController
    before_action :authenticate_user!
    before_action :require_admin!

    # GET /api/token_usage_analytics
    # Returns the 4 metrics (Evaluation input/output, Follow-up input/output), total, and extra stats.
    # Optional: since_days (e.g. 30) to scope to last N days.
    def index
      since_time = if params[:since_days].present?
        (params[:since_days].to_i).days.ago
      end

      analytics = TokenUsage.analytics(since_time: since_time)

      render_success(
        {
          evaluation_input: analytics[:evaluation_input],
          evaluation_output: analytics[:evaluation_output],
          followup_input: analytics[:followup_input],
          followup_output: analytics[:followup_output],
          total_tokens: analytics[:total_tokens],
          total_evaluation_tokens: analytics[:total_evaluation_tokens],
          total_followup_tokens: analytics[:total_followup_tokens],
          evaluations_count: analytics[:evaluations_count],
          followup_events_count: analytics[:followup_events_count],
          since_days: params[:since_days].presence&.to_i
        },
        message: 'Token usage analytics retrieved successfully'
      )
    end

    private

    def require_admin!
      return if current_user.admin?

      render_error(
        'forbidden',
        'Admin access required',
        status: :forbidden
      )
    end
  end
end
