class VectorStoreService
  include HTTParty
  
  base_uri 'https://api.openai.com/v1'
  
  DEFAULT_TIMEOUT = 60
  
  def initialize
    @api_key = ENV['OPENAI_API_KEY']
    @headers = {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json',
      'OpenAI-Beta' => 'assistants=v2'
    }
  end

  def create_vector_store(name, expires_after_days: 30, max_retries: 3)
    Rails.logger.info "Creating vector store: #{name}"
    
    payload = {
      name: name,
      expires_after: {
        anchor: 'last_active_at',
        days: expires_after_days
      }
    }
    
    retry_with_backoff(max_retries: max_retries, operation: "create vector store") do |attempt|
      Rails.logger.info "Vector store creation attempt #{attempt}/#{max_retries}"
      
      response = self.class.post(
        '/vector_stores',
        headers: @headers,
        body: payload.to_json,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        store_data = JSON.parse(response.body)
        Rails.logger.info "Successfully created vector store: #{store_data['id']}"
        store_data['id']
      else
        error_msg = "OpenAI API error: #{response.code} - #{response.body}"
        Rails.logger.error "Failed to create vector store: #{error_msg}"
        raise error_msg
      end
    end
  end

  def add_file_to_vector_store(vector_store_id, file_id, max_retries: 3)
    Rails.logger.info "Adding file #{file_id} to vector store #{vector_store_id}"
    
    retry_with_backoff(max_retries: max_retries, operation: "add file to vector store") do |attempt|
      Rails.logger.info "Add file to vector store attempt #{attempt}/#{max_retries}"
      
      response = self.class.post(
        "/vector_stores/#{vector_store_id}/files",
        headers: @headers,
        body: { file_id: file_id }.to_json,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        Rails.logger.info "Successfully added file to vector store"
        JSON.parse(response.body)
      else
        error_msg = "OpenAI API error: #{response.code} - #{response.body}"
        Rails.logger.error "Failed to add file to vector store: #{error_msg}"
        raise error_msg
      end
    end
  end

  def get_vector_store_status(vector_store_id, max_retries: 3)
    retry_with_backoff(max_retries: max_retries, operation: "get vector store status") do
      response = self.class.get(
        "/vector_stores/#{vector_store_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      if response.success?
        data = JSON.parse(response.body)
        # Check file_counts to see if processing is done
        # Status might be 'in_progress', 'completed', 'expired'
        data['status']
      else
        error_msg = "OpenAI API error: #{response.code} - #{response.body}"
        Rails.logger.error "Failed to get vector store status: #{error_msg}"
        raise error_msg
      end
    end
  end
  
  def wait_for_vector_store_ready(vector_store_id, timeout: 600, interval: 3, progress_callback: nil)
    start_time = Time.zone.now
    last_status = nil
    
    loop do
      # Check vector store status
      begin
        response = self.class.get(
          "/vector_stores/#{vector_store_id}",
          headers: @headers,
          timeout: DEFAULT_TIMEOUT
        )
        
        if response.success?
          data = JSON.parse(response.body)
          file_counts = data['file_counts'] || {}
          current_status = data['status']
          
          # Call progress callback if provided
          if progress_callback && current_status != last_status
            progress_callback.call(current_status, file_counts)
            last_status = current_status
          end
          
          # Check completion conditions
          if file_counts['in_progress'] == 0 && file_counts['failed'] == 0 && file_counts['completed'] > 0
            Rails.logger.info "Vector store #{vector_store_id} is ready"
            return 'completed'
          elsif file_counts['failed'] > 0
            Rails.logger.error "Vector store #{vector_store_id} has failed files"
            return 'failed'
          end
        end
      rescue => e
        Rails.logger.warn "Error checking vector store status: #{e.message}"
        # Continue polling on transient errors
      end
      
      # Check timeout
      elapsed = Time.zone.now - start_time
      if elapsed > timeout
        Rails.logger.warn "Timeout waiting for vector store #{vector_store_id} after #{elapsed.round}s"
        return 'timeout'
      end
      
      # Progressive interval: check more frequently at first, then less frequently
      current_interval = elapsed < 60 ? interval : [interval * 2, 10].min
      sleep current_interval
    end
  end

  def delete_vector_store(vector_store_id, max_retries: 3)
    unless vector_store_id.present?
      Rails.logger.warn "[VectorStoreService] delete_vector_store called with nil/empty vector_store_id"
      return false
    end
    
    Rails.logger.info "[VectorStoreService] Starting deletion of vector store: #{vector_store_id}"
    Rails.logger.info "[VectorStoreService] Max retries: #{max_retries}"
    
    result = retry_with_backoff(max_retries: max_retries, operation: "delete vector store", raise_on_failure: false) do |attempt|
      Rails.logger.info "[VectorStoreService] Delete attempt #{attempt}/#{max_retries} for vector store: #{vector_store_id}"
      
      response = self.class.delete(
        "/vector_stores/#{vector_store_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      Rails.logger.info "[VectorStoreService] API Response Code: #{response.code}"
      
      if response.success?
        Rails.logger.info "[VectorStoreService] ✅ Successfully deleted vector store: #{vector_store_id}"
        true
      else
        Rails.logger.error "[VectorStoreService] ❌ Failed to delete vector store: #{vector_store_id}"
        Rails.logger.error "[VectorStoreService] Response Code: #{response.code}"
        Rails.logger.error "[VectorStoreService] Response Body: #{response.body}"
        false
      end
    end
    
    if result
      Rails.logger.info "[VectorStoreService] Vector store deletion completed successfully: #{vector_store_id}"
    else
      Rails.logger.warn "[VectorStoreService] Vector store deletion failed or returned false: #{vector_store_id}"
    end
    
    result
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


