module Api
  class FilesController < ApplicationController
    before_action :authenticate_user!
    before_action :set_file, only: [:show, :destroy, :status]

    # GET /api/files
    def index
      page = params[:page]&.to_i || 1
      per_page = params[:per_page]&.to_i || 20
      status = params[:status]

      files = current_user.uploaded_files.active.recent
      files = files.where(status: status) if status.present?
      
      # Simple pagination without gem
      total_count = files.count
      total_pages = (total_count.to_f / per_page).ceil
      offset = (page - 1) * per_page
      paginated_files = files.limit(per_page).offset(offset)

      render_success(
        {
          files: paginated_files.map { |f| file_serializer(f) },
          pagination: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        },
        message: "Files retrieved successfully"
      )
    end

    # POST /api/files
    def create
      if params[:file].blank?
        return render_error("validation_error", "No file provided", status: :bad_request)
      end

      service = FileUploadService.new(current_user)
      uploaded_file = service.upload_and_process(params[:file])

      if uploaded_file.persisted?
        render_success(
          file_serializer(uploaded_file),
          message: "File uploaded successfully",
          status: :created
        )
      else
        render_error("validation_error", uploaded_file.errors.full_messages.join(", "), status: :unprocessable_entity)
      end
    rescue => e
      render_error("file_upload_error", e.message, status: :unprocessable_entity)
    end

    # GET /api/files/:id
    def show
      render_success(
        file_serializer(@file, include_evaluations: true),
        message: "File details retrieved successfully"
      )
    end

    # DELETE /api/files/:id
    def destroy
      @file.mark_as_deleted!
      
      # Cleanup OpenAI resources (could be async)
      begin
        service = OpenaiFileService.new
        service.delete_file(@file.openai_file_id) if @file.openai_file_id
        
        vs_service = VectorStoreService.new
        vs_service.delete_vector_store(@file.openai_vector_store_id) if @file.openai_vector_store_id
      rescue => e
        Rails.logger.error "Failed to cleanup OpenAI resources for file #{@file.id}: #{e.message}"
      end
      
      render_success(nil, message: "File deleted successfully")
    end

    # GET /api/files/:id/status
    def status
      # Optionally refresh from OpenAI if pending/processing
      if @file.vector_store_pending? || @file.vector_store_processing?
        begin
          vs_service = VectorStoreService.new
          status = vs_service.get_vector_store_status(@file.openai_vector_store_id)
          
          # Map OpenAI status to our enum
          # OpenAI: expired, in_progress, completed
          new_status = case status
                       when 'completed' then 'completed'
                       when 'in_progress' then 'processing'
                       when 'expired', 'failed' then 'failed'
                       else 'pending'
                       end
          
          @file.update(vector_store_status: new_status)
          
          if new_status == 'completed' && @file.status_processing?
            @file.mark_as_ready!
            @file.update!(progress_stage: 'completed')
          end
        rescue => e
          Rails.logger.error "Failed to refresh status: #{e.message}"
        end
      end
      
      render_success(
        {
          id: @file.id,
          status: @file.status,
          vector_store_status: @file.vector_store_status,
          progress_stage: @file.progress_stage,
          progress_message: @file.progress_stage_display,
          error_message: @file.error_message
        },
        message: "File status retrieved"
      )
    end

    private

    def set_file
      @file = current_user.uploaded_files.active.find(params[:id])
    end

    def file_serializer(file, include_evaluations: false)
      data = {
        id: file.id,
        filename: file.original_filename,
        display_name: file.display_name,
        size_mb: file.file_size_mb,
        uploaded_at: file.created_at,
        status: file.status,
        vector_store_status: file.vector_store_status,
        progress_stage: file.progress_stage,
        progress_message: file.progress_stage_display,
        expires_at: file.expires_at,
        last_analyzed_at: file.last_analyzed_at,
        error_message: file.error_message
      }
      
      if include_evaluations
        data[:evaluations] = file.evaluations.recent.limit(5).map do |e|
          {
            id: e.id,
            date: e.created_at,
            scheme: e.scheme.name,
            status: e.status,
            summary: e.summary_stats
          }
        end
      end
      
      data
    end
  end
end







