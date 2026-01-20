class OpenaiFileService
  include HTTParty
  
  base_uri 'https://api.openai.com/v1'
  
  # Timeout settings (in seconds)
  UPLOAD_TIMEOUT = 600 # 10 minutes for large files
  DEFAULT_TIMEOUT = 60
  
  def initialize
    @api_key = ENV['OPENAI_API_KEY']
    @headers = {
      'Authorization' => "Bearer #{@api_key}"
    }
  end

  def upload_file(file_path_or_io, purpose: 'assistants', max_retries: 3)
    Rails.logger.info "Uploading file to OpenAI with purpose: #{purpose}"
    
    retry_with_backoff(max_retries: max_retries, operation: "file upload") do |attempt|
      Rails.logger.info "File upload attempt #{attempt}/#{max_retries}"
      
      # Ensure file handle is valid
      file_handle = if file_path_or_io.is_a?(String)
        File.open(file_path_or_io, 'rb')
      elsif file_path_or_io.respond_to?(:read)
        file_path_or_io.rewind if file_path_or_io.respond_to?(:rewind)
        file_path_or_io
      else
        raise "Invalid file handle"
      end
      
      begin
        response = self.class.post(
          '/files',
          headers: @headers,
          multipart: true,
          timeout: UPLOAD_TIMEOUT,
          body: {
            purpose: purpose,
            file: file_handle
          }
        )
        
        if response.success?
          file_data = JSON.parse(response.body)
          Rails.logger.info "Successfully uploaded file to OpenAI: #{file_data['id']}"
          file_data['id']
        else
          error_msg = "OpenAI API error inside upload_file(): #{response.code} - #{response.body}"
          Rails.logger.error "Failed to upload file to OpenAI: #{error_msg}"
          raise error_msg
        end
      ensure
        # Close file handle if we opened it
        file_handle.close if file_path_or_io.is_a?(String) && file_handle.respond_to?(:close)
      end
    end
  end

  def get_file_status(file_id, max_retries: 3)
    retry_with_backoff(max_retries: max_retries, operation: "get file status") do
      response = self.class.get(
        "/files/#{file_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        JSON.parse(response.body)['status']
      else
        error_msg = "OpenAI API error inside get_file_status(): #{response.code} - #{response.body}"
        Rails.logger.error "Failed to get file status: #{error_msg}"
        raise error_msg
      end
    end
  end

  def delete_file(file_id, max_retries: 3)
    return unless file_id.present?
    
    Rails.logger.info "Deleting file from OpenAI: #{file_id}"
    
    retry_with_backoff(max_retries: max_retries, operation: "delete file", raise_on_failure: false) do
      response = self.class.delete(
        "/files/#{file_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        Rails.logger.info "Successfully deleted file from OpenAI: #{file_id}"
        true
      else
        Rails.logger.error "Failed to delete file from OpenAI inside delete_file(): #{response.body}"
        false
      end
    end
  end

  def get_file_details(file_id, max_retries: 3)
    retry_with_backoff(max_retries: max_retries, operation: "get file details") do
      response = self.class.get(
        "/files/#{file_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        JSON.parse(response.body)
      else
        error_msg = "OpenAI API error inside get_file_details(): #{response.code} - #{response.body}"
        Rails.logger.error "Failed to get file details: #{error_msg}"
        raise error_msg
      end
    end
  end

  private

  def retry_with_backoff(max_retries: 3, operation: "operation", raise_on_failure: true)
    attempt = 0
    last_error = nil
    
    while attempt < max_retries
      attempt += 1
      begin
        return yield(attempt)
      rescue => e
        last_error = e
        is_retryable = retryable_error?(e)
        
        if attempt < max_retries && is_retryable
          wait_time = calculate_backoff(attempt)
          Rails.logger.warn "#{operation} failed (attempt #{attempt}/#{max_retries}): #{e.message}. Retrying in #{wait_time}s..."
          sleep wait_time
        else
          Rails.logger.error "#{operation} failed after #{attempt} attempts: #{e.message}"
          raise e if raise_on_failure
          return false
        end
      end
    end
    
    raise last_error if raise_on_failure && last_error
    false
  end

  def retryable_error?(error)
    # Retry on network errors, timeouts, and 5xx server errors
    error_message = error.message.downcase
    
    return true if error_message.include?('timeout') || error_message.include?('timed out')
    return true if error_message.include?('connection') || error_message.include?('network')
    return true if error_message.include?('500') || error_message.include?('502') || 
                   error_message.include?('503') || error_message.include?('504')
    
    false
  end

  def calculate_backoff(attempt)
    # Exponential backoff: 2s, 4s, 8s
    [2 ** attempt, 10].min # Cap at 10 seconds
  end
end


