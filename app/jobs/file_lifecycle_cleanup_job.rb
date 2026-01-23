class FileLifecycleCleanupJob < ApplicationJob
  queue_as :default

  BATCH_SIZE = 10
  BATCH_DELAY = 2.seconds

  def perform
    start_time = Time.current
    logger.info "=" * 80
    logger.info "[FileLifecycleCleanupJob] ===== FILE LIFECYCLE CLEANUP JOB STARTED ====="
    logger.info "[FileLifecycleCleanupJob] Started at: #{start_time.strftime('%Y-%m-%d %H:%M:%S')}"
    logger.info "[FileLifecycleCleanupJob] Cleaning up ALL expired files (system-wide)"
    logger.info "=" * 80
    
    files_scope = UploadedFile.expired_for_cleanup
    total = files_scope.count
    
    logger.info "[FileLifecycleCleanupJob] Checking for expired files..."
    logger.info "[FileLifecycleCleanupJob] Found #{total} expired file(s) that need cleanup"
    
    if total == 0
      logger.info "[FileLifecycleCleanupJob] No expired files found. Cleanup job completed."
      logger.info "=" * 80
      return
    end
    
    logger.info "[FileLifecycleCleanupJob] Processing files in batches of #{BATCH_SIZE} with #{BATCH_DELAY}s delay between batches"
    logger.info "-" * 80
    
    processed_count = 0
    success_count = 0
    error_count = 0
    batch_number = 0

    files_scope.find_in_batches(batch_size: BATCH_SIZE) do |batch|
      batch_number += 1
      logger.info "[FileLifecycleCleanupJob] Processing Batch ##{batch_number} (#{batch.size} file(s))"
      logger.info "-" * 80
      
      batch.each_with_index do |uploaded_file, index|
        file_number = ((batch_number - 1) * BATCH_SIZE) + index + 1
        logger.info "[FileLifecycleCleanupJob] [#{file_number}/#{total}] Processing file ID: #{uploaded_file.id}"
        logger.info "[FileLifecycleCleanupJob]   - Filename: #{uploaded_file.original_filename}"
        logger.info "[FileLifecycleCleanupJob]   - Display Name: #{uploaded_file.display_name}"
        logger.info "[FileLifecycleCleanupJob]   - Status: #{uploaded_file.status}"
        logger.info "[FileLifecycleCleanupJob]   - Expires At: #{uploaded_file.expires_at}"
        logger.info "[FileLifecycleCleanupJob]   - Days Expired: #{((Time.current - uploaded_file.expires_at) / 1.day).round(2)}"
        logger.info "[FileLifecycleCleanupJob]   - OpenAI File ID: #{uploaded_file.openai_file_id || 'N/A'}"
        logger.info "[FileLifecycleCleanupJob]   - OpenAI Vector Store ID: #{uploaded_file.openai_vector_store_id || 'N/A'}"
        
        begin
          cleanup_file(uploaded_file)
          success_count += 1
          processed_count += 1
          logger.info "[FileLifecycleCleanupJob]   ✅ Successfully cleaned up file ID: #{uploaded_file.id}"
        rescue => e
          error_count += 1
          processed_count += 1
          logger.error "[FileLifecycleCleanupJob]   ❌ FAILED to cleanup file ID: #{uploaded_file.id}"
          logger.error "[FileLifecycleCleanupJob]   Error: #{e.class.name} - #{e.message}"
          logger.error "[FileLifecycleCleanupJob]   Backtrace: #{e.backtrace.first(5).join("\n")}"
        end
        
        logger.info "-" * 80
      end
      
      if batch.size == BATCH_SIZE && processed_count < total
        logger.info "[FileLifecycleCleanupJob] Waiting #{BATCH_DELAY}s before next batch..."
        sleep BATCH_DELAY
      end
    end

    end_time = Time.current
    duration = (end_time - start_time).round(2)
    
    logger.info "=" * 80
    logger.info "[FileLifecycleCleanupJob] ===== FILE LIFECYCLE CLEANUP JOB COMPLETED ====="
    logger.info "[FileLifecycleCleanupJob] Completed at: #{end_time.strftime('%Y-%m-%d %H:%M:%S')}"
    logger.info "[FileLifecycleCleanupJob] Total Duration: #{duration} seconds"
    logger.info "[FileLifecycleCleanupJob] Summary:"
    logger.info "[FileLifecycleCleanupJob]   - Total Files Found: #{total}"
    logger.info "[FileLifecycleCleanupJob]   - Files Processed: #{processed_count}"
    logger.info "[FileLifecycleCleanupJob]   - Successfully Cleaned: #{success_count}"
    logger.info "[FileLifecycleCleanupJob]   - Errors: #{error_count}"
    logger.info "=" * 80
  end

  private

  def cleanup_file(uploaded_file)
    logger.info "[FileLifecycleCleanupJob]   Starting cleanup for file ID: #{uploaded_file.id}"
    
    # Step 1: Cleanup OpenAI resources
    logger.info "[FileLifecycleCleanupJob]   Step 1: Cleaning up OpenAI resources..."
    service = FileUploadService.new(nil)
    service.cleanup_openai_resources(uploaded_file)
    logger.info "[FileLifecycleCleanupJob]   Step 1: ✅ OpenAI resources cleanup completed"
    
    # Step 2: Soft delete in database
    logger.info "[FileLifecycleCleanupJob]   Step 2: Soft deleting file in database..."
    uploaded_file.mark_as_deleted!(deletion_source: 'system')
    logger.info "[FileLifecycleCleanupJob]   Step 2: ✅ File soft deleted in database"
    logger.info "[FileLifecycleCleanupJob]   Step 2:   - Deleted At: #{uploaded_file.deleted_at}"
    logger.info "[FileLifecycleCleanupJob]   Step 2:   - Deletion Source: #{uploaded_file.deletion_source}"
    logger.info "[FileLifecycleCleanupJob]   Step 2:   - Status: #{uploaded_file.status}"
    
    logger.info "[FileLifecycleCleanupJob]   ✅ Complete cleanup successful for file ID: #{uploaded_file.id} (#{uploaded_file.original_filename})"
  rescue => e
    logger.error "[FileLifecycleCleanupJob]   ❌ Exception during cleanup of file ID: #{uploaded_file.id}"
    logger.error "[FileLifecycleCleanupJob]   Exception Class: #{e.class.name}"
    logger.error "[FileLifecycleCleanupJob]   Exception Message: #{e.message}"
    logger.error "[FileLifecycleCleanupJob]   Full Backtrace:"
    e.backtrace.first(10).each do |line|
      logger.error "[FileLifecycleCleanupJob]     #{line}"
    end
    raise e
  end
end

