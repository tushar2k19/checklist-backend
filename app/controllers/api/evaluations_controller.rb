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

      # 3. Get checklist items (support optional item_text overrides from Editor's Items)
      checklist_items = ChecklistItem.where(id: item_ids).index_by(&:id)
      overrides = (params[:checklist_item_overrides] || {}).stringify_keys
      valid_item_ids = item_ids.select { |id| (overrides[id.to_s].presence || checklist_items[id]&.item_text).present? }
      checklist_texts = valid_item_ids.map { |id| overrides[id.to_s].presence || checklist_items[id].item_text }

      if checklist_texts.empty?
        evaluation = current_user.evaluations.create!(
          uploaded_file: uploaded_file,
          scheme: scheme,
          document_type: doc_type,
          status: 'failed',
          total_checklist_items: 0
        )
        evaluation.mark_as_failed!("No valid checklist items found")
        return render_error("validation_error", "Invalid checklist items", status: :unprocessable_entity)
      end

      # 2. Create Evaluation record
      evaluation = current_user.evaluations.create!(
        uploaded_file: uploaded_file,
        scheme: scheme,
        document_type: doc_type,
        status: 'pending',
        total_checklist_items: checklist_texts.length
      )

      # 4. Enqueue background job - returns immediately
      EvaluationJob.perform_later(
        evaluation.id,
        checklist_texts,
        valid_item_ids,
        uploaded_file.id
      )

      render_success(
        evaluation_detail_serializer(evaluation).merge(logs: nil),
        message: "Evaluation started. Results will appear as they complete.",
        status: :created
      )
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
        processing_time: e.processing_time,
        total_checklist_items: e.total_checklist_items,
        error_message: e.error_message
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
      base[:progress] = progress_for(e) if e.processing?
      base
    end

    def progress_for(e)
      total = e.total_checklist_items || e.evaluation_checklist_items.count
      results_count = e.evaluation_checklist_items.count
      batch_size = 3
      total_batches = total.positive? ? (total.to_f / batch_size).ceil : 0
      batches_completed = total_batches.positive? ? results_count / batch_size : 0
      {
        results_count: results_count,
        total_items: total,
        total_batches: total_batches,
        batches_completed: batches_completed
      }
    end
  end
end


