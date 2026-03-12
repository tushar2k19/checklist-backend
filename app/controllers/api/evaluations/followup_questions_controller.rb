module Api
  module Evaluations
    class FollowupQuestionsController < ApplicationController
      before_action :authenticate_user!
      before_action :set_evaluation
      before_action :set_evaluation_checklist_item

      # GET /api/evaluations/:evaluation_id/followup_questions/:id
      def show
        thread_id = @evaluation_checklist_item.openai_followup_thread_id

        if thread_id.blank?
          return render_success(
            {
              thread_id: nil,
              messages: []
            },
            message: 'No follow-up thread found for this checklist item'
          )
        end

        openai_service = OpenaiService.new
        messages = openai_service.fetch_thread_messages(thread_id: thread_id)

        render_success(
          {
            thread_id: thread_id,
            messages: messages
          },
          message: 'Follow-up messages retrieved successfully'
        )
      rescue => e
        Rails.logger.error "Follow-up messages fetch failed: #{e.message}"
        render_error(
          'followup_fetch_failed',
          "Failed to fetch follow-up messages: #{e.message}",
          status: :service_unavailable
        )
      end

      # POST /api/evaluations/:evaluation_id/followup_questions
      def create
        message = followup_params[:message].to_s.strip
        if message.blank?
          return render_error(
            'validation_error',
            'message is required',
            status: :unprocessable_entity
          )
        end

        vector_store_id = @evaluation.uploaded_file&.openai_vector_store_id
        if vector_store_id.blank?
          return render_error(
            'vector_store_missing',
            'Document not available for follow-up questions',
            status: :unprocessable_entity
          )
        end

        openai_service = OpenaiService.new
        response = openai_service.ask_followup_question(
          evaluation_checklist_item: @evaluation_checklist_item,
          vector_store_id: vector_store_id,
          message: message,
          thread_id: @evaluation_checklist_item.openai_followup_thread_id
        )

        if response[:is_new_thread]
          @evaluation_checklist_item.update!(openai_followup_thread_id: response[:thread_id])
        end

        render_success(
          {
            answer: response[:answer],
            status: response[:status],
            thread_id: response[:thread_id],
            is_new_thread: response[:is_new_thread]
          },
          message: 'Follow-up question answered successfully'
        )
      rescue => e
        Rails.logger.error "Follow-up question failed: #{e.message}"
        render_error(
          'followup_question_failed',
          "Failed to answer follow-up question: #{e.message}",
          status: :service_unavailable
        )
      end

      private

      def set_evaluation
        @evaluation = current_user.evaluations.not_deleted.find(params[:evaluation_id])
      end

      def set_evaluation_checklist_item
        item_id = params[:id] || raw_followup_params[:evaluation_checklist_item_id]
        @evaluation_checklist_item = @evaluation.evaluation_checklist_items.find(item_id)
      end

      # Accept both top-level and nested followup_question params (e.g. from different clients)
      def raw_followup_params
        permitted = params.permit(:evaluation_id, :evaluation_checklist_item_id, :message, followup_question: [:evaluation_checklist_item_id, :message])
        nested = permitted[:followup_question]
        top = permitted.slice(:evaluation_checklist_item_id, :message)
        h = (nested || {}).to_h.merge(top.to_h)
        h.slice('evaluation_checklist_item_id', 'message').with_indifferent_access
      end

      def followup_params
        raw_followup_params
      end
    end
  end
end
