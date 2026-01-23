module Api
  class EvaluationsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_evaluation, only: [:show, :destroy]

    # GET /api/evaluations
    def index
      page = params[:page]&.to_i || 1
      per_page = params[:per_page]&.to_i || 20
      
      evaluations = current_user.evaluations.not_deleted.recent(params[:days]&.to_i || 30)
      
      if params[:scheme_id].present?
        evaluations = evaluations.where(scheme_id: params[:scheme_id])
      end
      
      if params[:document_type_id].present?
        evaluations = evaluations.where(document_type_id: params[:document_type_id])
      end
      
      if params[:uploaded_file_id].present?
        evaluations = evaluations.where(uploaded_file_id: params[:uploaded_file_id])
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
        start_time = Time.zone.now
        log_accumulator = [] # Initialize log accumulator
        analysis_response = perform_analysis_with_retry(
          uploaded_file: uploaded_file,
          checklist_items: checklist_texts,
          evaluation: evaluation,
          log_accumulator: log_accumulator
        )
        
        results = analysis_response[:results]
        thread_id = analysis_response[:thread_id]
        processing_time = (Time.zone.now - start_time).to_i
        logs = analysis_response[:logs] || ""
        
        # 5. Store results
        ActiveRecord::Base.transaction do
          results.each do |result|
            matched_item = checklist_items.values.find { |i| i.item_text == result['item'] }
            
            if matched_item
              evaluation.evaluation_checklist_items.create!(
                checklist_item: matched_item,
                status: result['status'],
                remarks: clean_remarks(result['remarks'])
              )
            end
          end
          
          # 6. Mark as completed with thread_id
          evaluation.mark_as_completed!(thread_id, processing_time, results)
          
          # Update file last analyzed
          uploaded_file.touch(:last_analyzed_at)
        end
        
        render_success(
          evaluation_detail_serializer(evaluation).merge(logs: logs),
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

    # DELETE /api/evaluations/:id
    def destroy
      if @evaluation.deleted?
        return render_error("already_deleted", "Evaluation has already been deleted", status: :unprocessable_entity)
      end
      
      @evaluation.soft_delete!(current_user)
      
      render_success(
        { id: @evaluation.id },
        message: "Evaluation deleted successfully"
      )
    end

    private

    def set_evaluation
      @evaluation = current_user.evaluations.not_deleted.find(params[:id])
    end
    
    # Clean remarks by removing citation patterns like 【12:12†filename.pdf】
    def clean_remarks(remarks)
      return '' if remarks.blank?
      
      # Remove citation patterns: 【anything】
      cleaned = remarks.gsub(/【[^】]*】/, '')
      
      # Remove dagger markers (†) that might be left behind
      cleaned = cleaned.gsub(/†/, '')
      
      # Clean up extra whitespace
      cleaned = cleaned.gsub(/\s{2,}/, ' ').strip
      
      cleaned
    end

    def evaluation_serializer(e)
      {
        id: e.id,
        date: e.created_at,
        scheme: e.scheme.name,
        document_type: e.document_type.name,
        filename: e.uploaded_file.original_filename,
        uploaded_file_id: e.uploaded_file_id,
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
    def perform_analysis_with_retry(uploaded_file:, checklist_items:, evaluation:, log_accumulator:, max_retries: 3)
      attempt = 0
      last_error = nil
      
      while attempt < max_retries
        attempt += 1
        begin
          log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [INFO] Evaluation #{evaluation.id}: Analysis attempt #{attempt}/#{max_retries}"
          log_accumulator << log_entry
          Rails.logger.info "Evaluation #{evaluation.id}: Analysis attempt #{attempt}/#{max_retries}"
          
          # Update evaluation status to processing before each attempt
          evaluation.update!(status: 'processing') if attempt == 1
          
          openai_service = OpenaiService.new(log_accumulator: log_accumulator)
          analysis_response = openai_service.analyze_checklist(
            uploaded_file_id: uploaded_file.openai_file_id,
            vector_store_id: uploaded_file.openai_vector_store_id,
            checklist_items: checklist_items
          )
          
          # Get logs from service
          logs = openai_service.get_logs
          analysis_response[:logs] = logs
          
          log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [INFO] Evaluation #{evaluation.id}: Analysis completed successfully on attempt #{attempt}"
          log_accumulator << log_entry
          Rails.logger.info "Evaluation #{evaluation.id}: Analysis completed successfully on attempt #{attempt}"
          return analysis_response
          
        rescue => e
          last_error = e
          is_retryable = retryable_error?(e)
          
          log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [WARN] Evaluation #{evaluation.id}: Analysis attempt #{attempt} failed: #{e.message}"
          log_accumulator << log_entry
          Rails.logger.warn "Evaluation #{evaluation.id}: Analysis attempt #{attempt} failed: #{e.message}"
          
          if attempt < max_retries && is_retryable
            wait_time = calculate_backoff(attempt)
            log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [WARN] Evaluation #{evaluation.id}: Retrying in #{wait_time}s... (attempt #{attempt + 1}/#{max_retries})"
            log_accumulator << log_entry
            Rails.logger.warn "Evaluation #{evaluation.id}: Retrying in #{wait_time}s... (attempt #{attempt + 1}/#{max_retries})"
            sleep wait_time
          else
            if !is_retryable
              log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [ERROR] Evaluation #{evaluation.id}: Non-retryable error, stopping retries"
              log_accumulator << log_entry
              Rails.logger.error "Evaluation #{evaluation.id}: Non-retryable error, stopping retries"
            else
              log_entry = "[#{Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')}] [ERROR] Evaluation #{evaluation.id}: Max retries (#{max_retries}) reached"
              log_accumulator << log_entry
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


