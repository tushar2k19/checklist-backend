class FileUploadService
  def initialize(user)
    @user = user
    @openai_file_service = OpenaiFileService.new
    @vector_store_service = VectorStoreService.new
  end

  def upload_and_process(file, retention_days: 30)
    uploaded_file = nil
    
    begin
      # 1. Validate file basics
      uploaded_file = @user.uploaded_files.create!(
        original_filename: file.original_filename,
        display_name: file.original_filename,
        file_size: file.size,
        mime_type: file.content_type,
        status: 'processing',
        vector_store_status: 'pending',
        progress_stage: 'validating'
      )
      
      uploaded_file.update_progress_stage!('validating')
      validate_file(file)
      
      # 2. Calculate hash for deduplication check
      file_content = file.read
      file.rewind # Reset pointer for upload
      sha256 = Digest::SHA256.hexdigest(file_content)
      
      # Check if duplicate exists (optional logic here)
      # duplicate = UploadedFile.find_by(sha256_hash: sha256, status: 'ready')
      # return duplicate if duplicate
      
      uploaded_file.update!(sha256_hash: sha256)
      
      # 3. Upload to OpenAI (with retry)
      uploaded_file.update_progress_stage!('uploading_file')
      Rails.logger.info "[FileUploadService] Starting file upload for file #{uploaded_file.id}"
      
      openai_file_id = @openai_file_service.upload_file(file.tempfile, max_retries: 3)
      uploaded_file.update!(openai_file_id: openai_file_id)
      Rails.logger.info "[FileUploadService] File uploaded to OpenAI: #{openai_file_id}"
      
      # 4. Create Vector Store (with retry)
      uploaded_file.update_progress_stage!('creating_vector_store')
      vector_store_name = "File: #{uploaded_file.original_filename} (#{uploaded_file.id})"
      vector_store_id = @vector_store_service.create_vector_store(vector_store_name, expires_after_days: retention_days, max_retries: 3)
      uploaded_file.update!(openai_vector_store_id: vector_store_id)
      Rails.logger.info "[FileUploadService] Vector store created: #{vector_store_id}"
      
      # 5. Add file to Vector Store (with retry)
      uploaded_file.update_progress_stage!('adding_file_to_vector_store')
      @vector_store_service.add_file_to_vector_store(vector_store_id, openai_file_id, max_retries: 3)
      uploaded_file.update!(vector_store_status: 'processing')
      Rails.logger.info "[FileUploadService] File added to vector store, waiting for embeddings..."
      
      # 6. Wait for processing (with progress callback)
      uploaded_file.update_progress_stage!('generating_embeddings')
      
      progress_callback = lambda do |status, file_counts|
        Rails.logger.info "[FileUploadService] Vector store status: #{status}, in_progress: #{file_counts['in_progress']}, completed: #{file_counts['completed']}"
      end
      
      status = @vector_store_service.wait_for_vector_store_ready(
        vector_store_id, 
        timeout: 600, # 10 minutes for large files
        interval: 3,
        progress_callback: progress_callback
      )
      
      if status == 'completed'
        uploaded_file.mark_as_ready!
        uploaded_file.update!(
          vector_store_status: 'completed',
          progress_stage: 'completed',
          uploaded_at: Time.current
        )
        Rails.logger.info "[FileUploadService] File processing completed successfully: #{uploaded_file.id}"
      elsif status == 'timeout'
        error_msg = "Vector store processing timed out after 10 minutes"
        uploaded_file.mark_as_error!(error_msg)
        uploaded_file.update!(vector_store_status: 'failed', progress_stage: 'error')
        Rails.logger.error "[FileUploadService] #{error_msg} for file #{uploaded_file.id}"
      else
        error_msg = "Vector store processing failed with status: #{status}"
        uploaded_file.mark_as_error!(error_msg)
        uploaded_file.update!(vector_store_status: 'failed', progress_stage: 'error')
        Rails.logger.error "[FileUploadService] #{error_msg} for file #{uploaded_file.id}"
      end
      
      uploaded_file
      
    rescue => e
      Rails.logger.error "[FileUploadService] File upload process failed: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      if uploaded_file
        uploaded_file.mark_as_error!(e.message)
        uploaded_file.update!(progress_stage: 'error')
        
        # Cleanup OpenAI resources if partially created
        cleanup_openai_resources(uploaded_file)
      end
      
      raise e
    end
  end

  private

  def validate_file(file)
    unless file.content_type == 'application/pdf'
      raise "Invalid file type. Only PDF is allowed."
    end
    
    if file.size > 100.megabytes
      raise "File too large. Maximum size is 100MB."
    end
  end

  def cleanup_openai_resources(uploaded_file)
    # Cleanup vector store first (if exists)
    if uploaded_file.openai_vector_store_id.present?
      begin
        @vector_store_service.delete_vector_store(uploaded_file.openai_vector_store_id, max_retries: 2)
        Rails.logger.info "[FileUploadService] Cleaned up vector store: #{uploaded_file.openai_vector_store_id}"
      rescue => e
        Rails.logger.error "[FileUploadService] Failed to cleanup vector store: #{e.message}"
      end
    end
    
    # Cleanup file (if exists)
    if uploaded_file.openai_file_id.present?
      begin
        @openai_file_service.delete_file(uploaded_file.openai_file_id, max_retries: 2)
        Rails.logger.info "[FileUploadService] Cleaned up OpenAI file: #{uploaded_file.openai_file_id}"
      rescue => e
        Rails.logger.error "[FileUploadService] Failed to cleanup OpenAI file: #{e.message}"
      end
    end
  end
end

