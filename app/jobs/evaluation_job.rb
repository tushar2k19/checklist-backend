# frozen_string_literal: true

class EvaluationJob < ApplicationJob
  queue_as :default

  retry_on StandardError, wait: 5.seconds, attempts: 3 do |job, error|
    evaluation = Evaluation.find_by(id: job.arguments.first)
    evaluation&.mark_as_failed!("Job failed after retries: #{error.message}")
    Rails.logger.error "EvaluationJob failed for evaluation #{job.arguments.first}: #{error.message}"
  end

  def perform(evaluation_id, checklist_texts, item_ids, uploaded_file_id)
    evaluation = Evaluation.find(evaluation_id)
    uploaded_file = UploadedFile.find(uploaded_file_id)

    return if evaluation.completed? || evaluation.failed?

    evaluation.update!(status: 'processing')

    # Build text -> ChecklistItem mapping (item_ids order matches checklist_texts)
    checklist_items = ChecklistItem.where(id: item_ids).index_by(&:id)
    text_to_item = checklist_texts.zip(item_ids).each_with_object({}) do |(text, id), h|
      item = checklist_items[id]
      h[text] = item if item
    end

    log_accumulator = []
    start_time = Time.zone.now

    on_batch_complete = lambda do |batch_results, batch_usage|
      ActiveRecord::Base.transaction do
        batch_results.each do |result|
          matched_item = text_to_item[result['item']] || checklist_items.values.find { |i| i.item_text == result['item'] }
          next unless matched_item

          evaluation.evaluation_checklist_items.create!(
            checklist_item: matched_item,
            status: result['status'],
            remarks: clean_remarks(result['remarks'])
          )
        end
      end
    end

    openai_service = OpenaiService.new(log_accumulator: log_accumulator)
    analysis_response = openai_service.analyze_checklist_streaming(
      uploaded_file_id: uploaded_file.openai_file_id,
      vector_store_id: uploaded_file.openai_vector_store_id,
      checklist_items: checklist_texts,
      batch_size: 3,
      on_batch_complete: on_batch_complete
    )

    processing_time = (Time.zone.now - start_time).to_i
    evaluation.mark_as_completed!(
      analysis_response[:thread_id],
      processing_time,
      evaluation.evaluation_checklist_items.includes(:checklist_item).map do |eci|
        { 'item' => eci.checklist_item.item_text, 'status' => eci.status, 'remarks' => eci.remarks }
      end
    )

    eval_in = analysis_response[:evaluation_input_tokens].to_i
    eval_out = analysis_response[:evaluation_output_tokens].to_i
    if eval_in.positive? || eval_out.positive?
      TokenUsage.record_evaluation!(
        user_id: evaluation.user_id,
        evaluation_id: evaluation.id,
        input_tokens: eval_in,
        output_tokens: eval_out
      )
    end

    uploaded_file.touch(:last_analyzed_at)
    Rails.logger.info "EvaluationJob completed for evaluation #{evaluation_id}"
  rescue => e
    evaluation&.mark_as_failed!(e.message)
    Rails.logger.error "EvaluationJob failed for evaluation #{evaluation_id}: #{e.message}"
    Rails.logger.error e.backtrace.first(10).join("\n")
    raise e
  end

  private

  def clean_remarks(remarks)
    return '' if remarks.blank?
    cleaned = remarks.gsub(/【[^】]*】/, '')
    cleaned = cleaned.gsub(/†/, '')
    cleaned.gsub(/\s{2,}/, ' ').strip
  end
end
