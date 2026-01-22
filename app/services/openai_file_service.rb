require 'fileutils'
require 'tmpdir'
require 'net/http'
require 'securerandom'
require 'stringio'

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

  def upload_file(file_path_or_io, purpose: 'assistants', filename: nil, max_retries: 3)
    Rails.logger.info "Uploading file to OpenAI with purpose: #{purpose}#{", filename: #{filename}" if filename}"
    
    retry_with_backoff(max_retries: max_retries, operation: "file upload") do |attempt|
      Rails.logger.info "File upload attempt #{attempt}/#{max_retries}"
      
      # Get the source file path
      source_path = if file_path_or_io.is_a?(String)
        file_path_or_io
      elsif file_path_or_io.respond_to?(:path)
        file_path_or_io.path
      else
        raise "Invalid file handle: must be a path or have a .path method"
      end
      
      # Determine the filename to use - prefer provided filename, fallback to basename
      effective_filename = if filename.present?
        filename
      else
        File.basename(source_path)
      end
      
      # Use Net::HTTP directly to manually construct multipart form data
      # This gives us full control over the Content-Disposition header with filename
      uri = URI('https://api.openai.com/v1/files')
      
      # Generate boundary for multipart form
      boundary = "----WebKitFormBoundary#{SecureRandom.hex(16)}"
      
      # Read file content in binary mode
      file_content = File.binread(source_path)
      
      # Escape filename for use in Content-Disposition header (RFC 2183)
      # Replace quotes and backslashes, but keep the filename readable
      escaped_filename = effective_filename.gsub(/["\\]/, '\\\0')
      
      # Manually construct multipart form data
      body = StringIO.new
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"purpose\"\r\n\r\n"
      body << "#{purpose}\r\n"
      body << "--#{boundary}\r\n"
      body << "Content-Disposition: form-data; name=\"file\"; filename=\"#{escaped_filename}\"\r\n"
      body << "Content-Type: application/pdf\r\n\r\n"
      body << file_content
      body << "\r\n--#{boundary}--\r\n"    
      
      # Create HTTP request
      req = Net::HTTP::Post.new(uri.path)
      req['Authorization'] = "Bearer #{@api_key}"
      req['Content-Type'] = "multipart/form-data; boundary=#{boundary}"
      
      # Get body as binary string
      body_string = body.string
      body_string.force_encoding('ASCII-8BIT') if body_string.respond_to?(:force_encoding)
      req.body = body_string
      
      # Send request
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = UPLOAD_TIMEOUT
      http.open_timeout = 30
      
      response = http.request(req)
      
      if response.code.to_i == 200 || response.code.to_i == 201
        file_data = JSON.parse(response.body)
        uploaded_filename = file_data['filename']
        Rails.logger.info "Successfully uploaded file to OpenAI: #{file_data['id']}, filename: #{uploaded_filename}"
        
        
        file_data['id']
      else
        error_msg = "OpenAI API error inside upload_file(): #{response.code} - #{response.body}"
        Rails.logger.error "Failed to upload file to OpenAI: #{error_msg}"
        raise error_msg
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
    unless file_id.present?
      Rails.logger.warn "[OpenaiFileService] delete_file called with nil/empty file_id"
      return false
    end
    
    Rails.logger.info "[OpenaiFileService] Starting deletion of OpenAI file: #{file_id}"
    Rails.logger.info "[OpenaiFileService] Max retries: #{max_retries}"
    
    result = retry_with_backoff(max_retries: max_retries, operation: "delete file", raise_on_failure: false) do |attempt|
      Rails.logger.info "[OpenaiFileService] Delete attempt #{attempt}/#{max_retries} for file: #{file_id}"
      
      response = self.class.delete(
        "/files/#{file_id}",
        headers: @headers,
        timeout: DEFAULT_TIMEOUT
      )
      
      Rails.logger.info "[OpenaiFileService] API Response Code: #{response.code}"
      
      if response.success?
        Rails.logger.info "[OpenaiFileService] ✅ Successfully deleted file from OpenAI: #{file_id}"
        true
      else
        Rails.logger.error "[OpenaiFileService] ❌ Failed to delete file from OpenAI: #{file_id}"
        Rails.logger.error "[OpenaiFileService] Response Code: #{response.code}"
        Rails.logger.error "[OpenaiFileService] Response Body: #{response.body}"
        false
      end
    end
    
    if result
      Rails.logger.info "[OpenaiFileService] File deletion completed successfully: #{file_id}"
    else
      Rails.logger.warn "[OpenaiFileService] File deletion failed or returned false: #{file_id}"
    end
    
    result
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


