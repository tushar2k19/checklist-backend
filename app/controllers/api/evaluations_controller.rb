module Api
  class EvaluationsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_evaluation, only: [:show]

    # GET /api/evaluations
    def index
      page = params[:page]&.to_i || 1
      per_page = params[:per_page]&.to_i || 20
      
      evaluations = current_user.evaluations.recent(params[:days]&.to_i || 30)
      
      if params[:scheme_id].present?
        evaluations = evaluations.where(scheme_id: params[:scheme_id])
      end
      
      if params[:document_type_id].present?
        evaluations = evaluations.where(document_type_id: params[:document_type_id])
      end

      # Simple pagination without gem
      total_count = evaluations.count
      total_pages = (total_count.to_f / per_page).ceil
      offset = (page - 1) * per_page
      paginated_evaluations = evaluations.includes(:scheme, :document_type, :uploaded_file).limit(per_page).offset(offset)

      render_success(
        {
          evaluations: paginated_evaluations.map { |e| evaluation_serializer(e) },
          pagination: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        },
        message: "Evaluations retrieved successfully"
      )
    end

    # POST /api/evaluations
    def create
      # 1. Handle file upload if file is provided, otherwise use existing file
      if params[:file].present?
        # Upload new file
        service = FileUploadService.new(current_user)
        uploaded_file = service.upload_and_process(params[:file])
        
        unless uploaded_file.ready_for_analysis?
          return render_error(
            "file_not_ready",
            "File upload completed but is not ready for analysis. Status: #{uploaded_file.status}, Progress: #{uploaded_file.progress_stage_display}",
            status: :unprocessable_entity
          )
        end
      elsif params[:uploaded_file_id].present?
        # Use existing file
        uploaded_file = current_user.uploaded_files.find(params[:uploaded_file_id])
        
        unless uploaded_file.ready_for_analysis?
          return render_error("file_not_ready", "File is not ready for analysis (Status: #{uploaded_file.status})", status: :unprocessable_entity)
        end
      else
        return render_error("validation_error", "Either 'file' or 'uploaded_file_id' must be provided", status: :bad_request)
      end
      
      # 2. Validate other params
      scheme = Scheme.find(params[:scheme_id])
      doc_type = DocumentType.find(params[:document_type_id])
      item_ids = params[:checklist_item_ids]
      
      if item_ids.blank? || !item_ids.is_a?(Array)
        return render_error("validation_error", "checklist_item_ids must be a non-empty array", status: :bad_request)
      end

      # 2. Create Evaluation record
      evaluation = current_user.evaluations.create!(
        uploaded_file: uploaded_file,
        scheme: scheme,
        document_type: doc_type,
        status: 'pending'
      )
      
      # 3. Get checklist items
      checklist_items = ChecklistItem.where(id: item_ids).index_by(&:id)
      checklist_texts = item_ids.map { |id| checklist_items[id]&.item_text }.compact
      
      if checklist_texts.empty?
        evaluation.mark_as_failed!("No valid checklist items found")
        return render_error("validation_error", "Invalid checklist items", status: :unprocessable_entity)
      end

      begin
        # 4. Call OpenAI Service with retry logic
        start_time = Time.now
        analysis_response = perform_analysis_with_retry(
          uploaded_file: uploaded_file,
          checklist_items: checklist_texts,
          evaluation: evaluation
        )
        
        results = analysis_response[:results]
        thread_id = analysis_response[:thread_id]
        processing_time = (Time.now - start_time).to_i
        
        # 5. Store results
        ActiveRecord::Base.transaction do
          results.each do |result|
            matched_item = checklist_items.values.find { |i| i.item_text == result['item'] }
            
            if matched_item
              evaluation.evaluation_checklist_items.create!(
                checklist_item: matched_item,
                status: result['status'],
                remarks: result['remarks']
              )
            end
          end
          
          # 6. Mark as completed with thread_id
          evaluation.mark_as_completed!(thread_id, processing_time, results)
          
          # Update file last analyzed
          uploaded_file.touch(:last_analyzed_at)
        end
        
        render_success(
          evaluation_detail_serializer(evaluation),
          message: "Evaluation completed successfully",
          status: :created
        )
        
      rescue => e
        evaluation.mark_as_failed!(e.message)
        Rails.logger.error "Evaluation #{evaluation.id} failed after retries: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render_error("evaluation_failed", "Evaluation failed: #{e.message}", status: :internal_server_error)
      end
    end

    # GET /api/evaluations/:id
    def show
      render_success(
        evaluation_detail_serializer(@evaluation),
        message: "Evaluation details retrieved successfully"
      )
    end

    private

    def set_evaluation
      @evaluation = current_user.evaluations.find(params[:id])
    end

    def evaluation_serializer(e)
      {
        id: e.id,
        date: e.created_at,
        scheme: e.scheme.name,
        document_type: e.document_type.name,
        filename: e.uploaded_file.original_filename,
        status: e.status,
        summary: e.summary_stats,
        processing_time: e.processing_time
      }
    end
    
    def evaluation_detail_serializer(e)
      base = evaluation_serializer(e)
      base[:results] = e.evaluation_checklist_items.includes(:checklist_item).map do |item|
        {
          id: item.id,
          item_text: item.checklist_item.item_text,
          status: item.status,
          remarks: item.remarks
        }
      end
      base
    end
    
    # Perform analysis with retry logic (3 attempts, exponential backoff)
    def perform_analysis_with_retry(uploaded_file:, checklist_items:, evaluation:, max_retries: 3)
      attempt = 0
      last_error = nil
      
      while attempt < max_retries
        attempt += 1
        begin
          Rails.logger.info "Evaluation #{evaluation.id}: Analysis attempt #{attempt}/#{max_retries}"
          
          # Update evaluation status to processing before each attempt
          evaluation.update!(status: 'processing') if attempt == 1
          
          openai_service = OpenaiService.new
          analysis_response = openai_service.analyze_checklist(
            uploaded_file_id: uploaded_file.openai_file_id,
            vector_store_id: uploaded_file.openai_vector_store_id,
            checklist_items: checklist_items
          )
          
          Rails.logger.info "Evaluation #{evaluation.id}: Analysis completed successfully on attempt #{attempt}"
          return analysis_response
          
        rescue => e
          last_error = e
          is_retryable = retryable_error?(e)
          
          Rails.logger.warn "Evaluation #{evaluation.id}: Analysis attempt #{attempt} failed: #{e.message}"
          
          if attempt < max_retries && is_retryable
            wait_time = calculate_backoff(attempt)
            Rails.logger.warn "Evaluation #{evaluation.id}: Retrying in #{wait_time}s... (attempt #{attempt + 1}/#{max_retries})"
            sleep wait_time
          else
            if !is_retryable
              Rails.logger.error "Evaluation #{evaluation.id}: Non-retryable error, stopping retries"
            else
              Rails.logger.error "Evaluation #{evaluation.id}: Max retries (#{max_retries}) reached"
            end
            raise e
          end
        end
      end
      
      raise last_error if last_error
    end
    
    # Check if error is retryable
    def retryable_error?(error)
      error_message = error.message.downcase
      
      # Retry on network errors, timeouts, and 5xx server errors
      return true if error_message.include?('timeout') || error_message.include?('timed out')
      return true if error_message.include?('connection') || error_message.include?('network')
      return true if error_message.include?('500') || error_message.include?('502') || 
                     error_message.include?('503') || error_message.include?('504')
      
      # Retry on OpenAI API rate limits and temporary errors
      return true if error_message.include?('rate limit') || error_message.include?('429')
      return true if error_message.include?('service unavailable') || error_message.include?('temporary')
      
      false
    end
    
    # Calculate exponential backoff delay
    def calculate_backoff(attempt)
      # Exponential backoff: 2s, 4s, 8s (capped at 10 seconds)
      [2 ** attempt, 10].min
    end
  end
end


