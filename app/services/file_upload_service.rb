require 'digest'

class FileUploadService
  # Custom exception for duplicate file detection
  class DuplicateFileError < StandardError
    attr_reader :existing_file
    
    def initialize(existing_file)
      @existing_file = existing_file
      super("File already exists")
    end
  end

  def initialize(user)
    @user = user
    @openai_file_service = OpenaiFileService.new
    @vector_store_service = VectorStoreService.new
  end

  def upload_and_process(file, retention_days: 30)
    uploaded_file = nil
    
    begin
      # 1. Validate file basics
      validate_file(file)
      
      # 2. Calculate SHA256 hash for deduplication check
      file_content = file.read
      file.rewind # Reset pointer for upload
      sha256 = Digest::SHA256.hexdigest(file_content)
      
      # 3. Check for duplicate file (same SHA256 hash)
      existing_file = check_for_duplicate(sha256)
      
      if existing_file
        # If file exists and is NOT expired, raise duplicate error
        unless existing_file.expired?
          raise DuplicateFileError.new(existing_file)
        end
        
        # If file exists but IS expired, allow re-upload
        # The existing file record will remain in DB but we'll create a new one
        Rails.logger.info "[FileUploadService] Found expired duplicate file (ID: #{existing_file.id}), allowing re-upload"
      end
      
      # 4. Create new uploaded_file record
      uploaded_file = @user.uploaded_files.create!(
        original_filename: file.original_filename,
        display_name: file.original_filename,
        file_size: file.size,
        mime_type: file.content_type,
        status: 'processing',
        vector_store_status: 'pending',
        progress_stage: 'validating',
        sha256_hash: sha256
      )
      
      uploaded_file.update_progress_stage!('validating')
      
      # 5. Upload to OpenAI (with retry)
      uploaded_file.update_progress_stage!('uploading_file')
      Rails.logger.info "[FileUploadService] Starting file upload for file #{uploaded_file.id}"
      
      # Use file.original_filename directly to ensure we have the correct filename
      original_filename = file.original_filename || uploaded_file.original_filename
      Rails.logger.info "[FileUploadService] Using original filename: #{original_filename}"
      
      openai_file_id = @openai_file_service.upload_file(
        file.tempfile, 
        filename: original_filename, 
        max_retries: 3
      )
      uploaded_file.update!(openai_file_id: openai_file_id)
      Rails.logger.info "[FileUploadService] File uploaded to OpenAI: #{openai_file_id}"
      
      # 6. Create Vector Store (with retry)
      uploaded_file.update_progress_stage!('creating_vector_store')
      vector_store_name = "File: #{uploaded_file.original_filename} (#{uploaded_file.id})"
      vector_store_id = @vector_store_service.create_vector_store(vector_store_name, expires_after_days: retention_days, max_retries: 3)
      uploaded_file.update!(openai_vector_store_id: vector_store_id)
      Rails.logger.info "[FileUploadService] Vector store created: #{vector_store_id}"
      
      # 7. Add file to Vector Store (with retry)
      uploaded_file.update_progress_stage!('adding_file_to_vector_store')
      @vector_store_service.add_file_to_vector_store(vector_store_id, openai_file_id, max_retries: 3)
      uploaded_file.update!(vector_store_status: 'processing')
      Rails.logger.info "[FileUploadService] File added to vector store, waiting for embeddings..."
      
      # 8. Wait for processing (with progress callback)
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
      
    rescue DuplicateFileError => e
      # Re-raise duplicate file error (will be handled by controller)
      raise e
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

  def check_for_duplicate(sha256_hash)
    # Find existing file with same SHA256 hash for the same user
    # Check both active and expired files, but only block if not expired
    existing_file = @user.uploaded_files
      .where(sha256_hash: sha256_hash)
      .where.not(status: 'deleted')
      .order(created_at: :desc)
      .first
    
    return nil unless existing_file
    
    # Return the existing file (caller will check if it's expired)
    existing_file
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
