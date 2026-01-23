class OpenaiService
  include HTTParty
  
  # Base configuration
  base_uri 'https://api.openai.com/v1'
  
  def initialize(log_accumulator: nil)
    @api_key = ENV['OPENAI_API_KEY']
    @assistant_id = ENV['Checklist_ASSISTANT_ID']
    @model = ENV['OPENAI_MODEL'] || 'gpt-4o'
    @log_accumulator = log_accumulator || []
    
    @headers = {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json',
      'OpenAI-Beta' => 'assistants=v2'
    }
  end
  
  # Add log entry to accumulator
  def add_log(level, message)
    timestamp = Time.zone.now.strftime('%Y-%m-%d %H:%M:%S %Z')
    log_entry = "[#{timestamp}] [#{level.upcase}] #{message}"
    @log_accumulator << log_entry if @log_accumulator
    Rails.logger.send(level.downcase.to_sym, message)
  end
  
  # Get all logs as string
  def get_logs
    @log_accumulator ? @log_accumulator.join("\n") : ""
  end

  # Analyze a checklist against a specific file (using vector store)
  # Supports batch processing for better accuracy (processes 3 items at a time)
  # Uses SINGLE THREAD for entire evaluation to avoid concurrency issues
  # Includes robust retry logic for failed batches
  def analyze_checklist(uploaded_file_id: nil, vector_store_id:, checklist_items:, batch_size: 3)
    add_log('info', "=== Starting Checklist Analysis ===")
    add_log('info', "Total items: #{checklist_items.length}, Batch size: #{batch_size}")
    
    # Create ONE thread for entire evaluation (reused across all batches)
    thread_id = create_thread(vector_store_id)
    add_log('info', "Created single thread #{thread_id} for entire evaluation")
    
    # For small lists (<=3 items), process normally with retry
    if checklist_items.length <= batch_size
      Rails.logger.info "Processing all items in single batch"
      return analyze_checklist_batch_with_retry(thread_id, checklist_items, 1, 1)
    end
    
    # Batch processing for larger lists with retry logic (using SAME thread)
    all_results = []
    batches = checklist_items.each_slice(batch_size).to_a
    total_batches = batches.length
    
    batches.each_with_index do |batch_items, batch_index|
      batch_num = batch_index + 1
      add_log('info', "Processing batch #{batch_num}/#{total_batches} (#{batch_items.length} items) on thread #{thread_id}")
      
      begin
        # Process batch with retry logic (reusing same thread)
        batch_result = analyze_checklist_batch_with_retry(
          thread_id, 
          batch_items, 
          batch_num, 
          total_batches,
          max_retries: 3
        )
        all_results.concat(batch_result[:results])
        
        # Longer delay between batches for large files (5 seconds)
        if batch_index < batches.length - 1
          add_log('info', "Waiting 5 seconds before next batch (allows OpenAI to process large file)...")
          sleep 5
        end
      rescue => e
        add_log('error', "Batch #{batch_num} failed after all retries: #{e.message}")
        add_log('error', "Error class: #{e.class}, Backtrace: #{e.backtrace.first(3).join(', ')}")
        
        # Create placeholder results for failed batch items
        batch_items.each do |item|
          all_results << {
            'item' => item,
            'status' => 'No',
            'remarks' => "Analysis failed for this item after multiple retry attempts: #{e.message}"
          }
        end
      end
    end
    
    # Return combined results with the single thread_id
    {
      results: all_results,
      thread_id: thread_id
    }
  end
  
  # Analyze a single batch with retry logic
  # Now accepts thread_id instead of vector_store_id to reuse same thread
  def analyze_checklist_batch_with_retry(thread_id, checklist_items, batch_num, total_batches, max_retries: 3)
    attempt = 0
    last_error = nil
    
    while attempt < max_retries
      attempt += 1
      begin
        add_log('info', "Batch #{batch_num}: Attempt #{attempt}/#{max_retries} on thread #{thread_id}")
        
        batch_result = analyze_checklist_batch(thread_id, checklist_items, batch_num, total_batches)
        
        add_log('info', "Batch #{batch_num}: Successfully completed on attempt #{attempt}")
        return batch_result
        
      rescue => e
        last_error = e
        is_retryable = is_retryable_error?(e)
        
        add_log('warn', "Batch #{batch_num}: Attempt #{attempt} failed: #{e.message}")
        add_log('warn', "Error class: #{e.class}, Retryable: #{is_retryable}")
        
        if attempt < max_retries && is_retryable
          # Longer backoff for large file processing: 10s, 20s, 40s (capped at 45s)
          wait_time = [10 * (2 ** (attempt - 1)), 45].min
          add_log('warn', "Batch #{batch_num}: Retrying in #{wait_time}s... (attempt #{attempt + 1}/#{max_retries})")
          sleep wait_time
        else
          if !is_retryable
            add_log('error', "Batch #{batch_num}: Non-retryable error, stopping retries")
          else
            add_log('error', "Batch #{batch_num}: Max retries (#{max_retries}) reached")
          end
          raise e
        end
      end
    end
    
    raise last_error if last_error
  end
  
  # Analyze a single batch of checklist items (no retry - called by retry wrapper)
  # Now accepts thread_id directly (reused across batches)
  def analyze_checklist_batch(thread_id, checklist_items, batch_num, total_batches)
    begin
      # Thread is already created and reused
      # Step 1: Build the prompt with multi-angle instructions and examples
      prompt = build_checklist_prompt(checklist_items, batch_num, total_batches)
      
      # Step 2: Send message
      send_message(thread_id, prompt)
      
      # Step 3: Create run with increased timeout for large files
      run_id = create_checklist_run(thread_id)
      
      # Step 4: Wait for completion (longer timeout for large PDF processing)
      start_time = Time.zone.now
      run_data = wait_for_run_completion(thread_id, run_id, timeout: 420) # 7 minutes for 34MB files
      
      # Step 4.5: If requires_action, extract results first, then submit tool outputs
      if run_data['status'] == 'requires_action'
        add_log('info', "Run requires action, extracting results from function call...")
        # Extract results from function call arguments BEFORE submitting tool outputs
        results = extract_results_from_requires_action(run_data)
        
        if results.length > 0
          add_log('info', "Found #{results.length} results from requires_action, submitting tool outputs...")
          # Submit tool outputs to acknowledge the function call
          submit_tool_outputs(thread_id, run_id, run_data)
          
          # CRITICAL: Wait for run to fully complete before returning
          # This prevents "Can't add messages while run is active" error on next batch
          # After tool outputs, we MUST wait for 'completed' status only (not 'requires_action')
          add_log('info', "Waiting for run to fully complete after tool outputs submission...")
          wait_for_run_to_fully_complete(thread_id, run_id, timeout: 120)
          add_log('info', "Run fully completed, safe to proceed to next batch")
          
          # Results are already extracted, return them
          return {
            results: results,
            thread_id: thread_id
          }
        else
          add_log('warn', "No results found in requires_action, submitting tool outputs and checking messages...")
          submit_tool_outputs(thread_id, run_id, run_data)
          # Wait for FULL completion after submitting tool outputs (must be 'completed', not 'requires_action')
          run_data = wait_for_run_to_fully_complete(thread_id, run_id, timeout: 420)
        end
      end
      
      # Step 5: Process results (for completed runs)
      results = process_checklist_response(thread_id, run_data, checklist_items)
      
      # Step 5.5: Log if we got plain text response instead of function call
      if results.length == 0 && run_data['status'] == 'completed'
        add_log('error', "====== PLAIN TEXT RESPONSE DETECTED ======")
        add_log('error', "Run completed without function call. Fetching assistant's response...")
        plain_text = extract_plain_text_response(thread_id)
        if plain_text
          add_log('error', "Plain text response (first 500 chars): #{plain_text[0..500]}")
          add_log('error', "=========================================")
        end
      end
      
      # Validate results match checklist items - treat 0 results as failure
      if results.length == 0
        add_log('error', "Batch #{batch_num}: No results returned (0 results for #{checklist_items.length} items)")
        raise "No results returned from OpenAI API. Expected #{checklist_items.length} results, got 0."
      elsif results.length != checklist_items.length
        add_log('warn', "Batch #{batch_num}: Results count (#{results.length}) doesn't match items count (#{checklist_items.length})")
        # This is a warning but not a failure - we'll use what we got
      end
      
      # Return BOTH results and thread_id
      {
        results: results,
        thread_id: thread_id
      }
      
    rescue => e
      add_log('error', "Batch Analysis Failed: #{e.message}")
      add_log('error', "Error class: #{e.class}")
      raise e
    end
  end
  
  private

  def create_thread(vector_store_id)
    payload = {
      tool_resources: {
        file_search: {
          vector_store_ids: [vector_store_id]
        }
      }
    }
    
    response = self.class.post('/threads', headers: @headers, body: payload.to_json)
    handle_response(response)['id']
  end

  def send_message(thread_id, content)
    payload = {
      role: 'user',
      content: content
    }
    
    response = self.class.post("/threads/#{thread_id}/messages", headers: @headers, body: payload.to_json)
    handle_response(response)['id']
  end
  
  def build_checklist_prompt(checklist_items, batch_num = nil, total_batches = nil)
    items_list = checklist_items.map.with_index(1) { |item, i| "#{i}. #{item}" }.join("\n")
    batch_info = batch_num && total_batches ? "\n\nBATCH INFORMATION: This is batch #{batch_num} of #{total_batches}. Analyze only the items listed below for this batch." : ""
    
    <<~PROMPT
      You are a specialized DPR (Detailed Project Report) Compliance Auditor with expertise in government project documentation.
      
      CORE RULES (STRICT ADHERENCE REQUIRED):
      1. Your analysis MUST be based ONLY on the document provided in the vector store for this thread. Do NOT use any external or prior knowledge.
      2. You MUST thoroughly search the document EXTENSIVELY for EACH checklist item to retrieve all relevant information.
      3. Search thoroughly: Information may be in different sections, pages, or use different terminology. Explore all relevant keywords and synonyms.
      4. Explicitly ignore all previous knowledge of state projects or other DPRs. If your response contains information not found in the current document, you MUST state so clearly in the remarks.
      5. If the document is a general document (e.g., proposal, random PDF) and not a valid DPR, mark all items as "No" and state "Document is not a valid DPR" in the remarks for each item.
      6. When in doubt about whether information exists, perform additional searches using different keywords related to the checklist item to confirm its presence or absence.
#{batch_info}
      
      CHECKLIST FOR EVALUATION (Analyze ALL items below):
      #{items_list}

      CRITICAL SEARCH INSTRUCTIONS (For EACH checklist item):
      - Thoroughly search the document for relevant information.
      - Search using the exact item text AND related keywords/synonyms.
      - Explicitly check multiple sections of the document, as information may be spread across different pages.
      - Look for partial matches; sometimes, information exists but uses different terminology.
      - Only mark as "No" if you have exhaustively searched and confirmed the information is truly missing from the provided document.

      STATUS EVALUATION GUIDELINES:
      - "Yes": The item is fully addressed, with all required information clearly present and verifiable within the provided document.
      - "Partial": The item is partially addressed – some information exists, but crucial aspects are missing or incomplete within the provided document.
      - "No": After thorough and exhaustive searching, the required information is conclusively not found in the provided document.

      INSTRUCTIONS FOR REMARKS (Multi-Angle - Provide specific details/citations from the document):
      - If "Yes": Provide a comprehensive (100+ words) technical summary. Explicitly mention specific values, departments, dates, or page references found in the text. Clearly cite where the information appears within the document.
      - If "Partial": Clearly articulate what information IS present and what specific aspects are MISSING. Explain why the item is considered incomplete based *only* on the provided document.
      - If "No": After confirming an exhaustive search, explicitly state: "Information regarding [Item] was not found in the provided document after extensive and thorough review."

      EXAMPLES OF QUALITY ANALYSIS:
      - Angle 1 (Technical/Financial): "Yes. The report (page 12) specifies a total project cost of ₹45.6 Cr, with a clear breakdown into Civil (₹30Cr) and Electrical (₹15.6Cr) components. Implementation is scheduled over 18 months, with quarterly milestones detailed in section 4.2 of the DPR."
      - Angle 2 (Administrative/Compliance): "Partial. The document (chapter 3) mentions environmental impact assessment and forest clearance procedures. However, the specific 'No Objection Certificate' from the State Forest Department, mandatory as per guidelines section 5.2, is explicitly missing from the provided document."
      - Angle 3 (Strategic/Rationale): "No. After extensive searching the document, information regarding the specific intended beneficiaries and their identification process was not found in the provided document."

      MANDATORY: You MUST return your findings by calling the 'return_checklist_results' function. Ensure you analyze ALL items in the checklist above, strictly adhering to the document provided. Your responses MUST ONLY reflect information found in the CURRENT document.
       PROMPT
  end
  
  def create_checklist_run(thread_id)
      payload = {
        assistant_id: @assistant_id,
        tools: [
          { type: "file_search" },
          {
            type: "function",
            function: {
              name: "return_checklist_results",
            description: "Return the results of the checklist analysis",
              parameters: {
                type: "object",
                properties: {
                  results: {
                    type: "array",
                    items: {
                      type: "object",
                      properties: {
                      item: { type: "string" },
                      status: { type: "string", enum: ["Yes", "No", "Partial"] },
                      remarks: { type: "string" }
                      },
                      required: ["item", "status", "remarks"]
                    }
                  }
                },
                required: ["results"]
              }
            }
          }
        ]
      }
      
    response = self.class.post("/threads/#{thread_id}/runs", headers: @headers, body: payload.to_json)
    handle_response(response)['id']
  end
  
  # Wait for run completion - returns on 'completed' OR 'requires_action'
  # Used for initial wait to catch function calls
  def wait_for_run_completion(thread_id, run_id, timeout: 120)
    start_time = Time.zone.now
    check_interval = 2 # Check every 2 seconds
    
    loop do
      elapsed = Time.zone.now - start_time
      if elapsed > timeout
        raise "Run timed out after #{timeout} seconds"
      end
      
      begin
        response = self.class.get("/threads/#{thread_id}/runs/#{run_id}", headers: @headers)
        run_data = handle_response(response)
        status = run_data['status']
        
        # Return on 'completed' OR 'requires_action' (for initial wait to catch function calls)
        return run_data if ['completed', 'requires_action'].include?(status)
        
        if ['failed', 'cancelled', 'expired'].include?(status)
          error_info = run_data['last_error'] || {}
          
          # Extract error details properly
          error_message = if error_info.is_a?(Hash)
            code = error_info['code'] || 'unknown'
            message = error_info['message'] || 'Unknown error'
            "{\"code\":\"#{code}\",\"message\":\"#{message}\"}"
          elsif error_info.is_a?(String)
            error_info
          else
            error_info.to_s
          end
          
          add_log('error', "Run #{run_id} failed with status: #{status}, error: #{error_message}")
          raise "Run failed: #{error_message}"
        end
        
        # Log progress for long-running runs
        if elapsed > 30 && elapsed % 30 < check_interval
          add_log('info', "Run #{run_id} still in progress (status: #{status}, elapsed: #{elapsed.round}s)")
        end
        
        sleep check_interval
      rescue => e
        # If it's a network/API error, re-raise for retry logic
        if e.message.include?('OpenAI API Error') || e.message.include?('server_error')
          raise e
        end
        # Otherwise, continue checking
        sleep check_interval
      end
    end
  end
  
  # Wait for run to FULLY complete - ONLY returns on 'completed' status
  # Used after submitting tool outputs to ensure run is completely done
  def wait_for_run_to_fully_complete(thread_id, run_id, timeout: 120)
    start_time = Time.zone.now
    check_interval = 2 # Check every 2 seconds
    
    loop do
      elapsed = Time.zone.now - start_time
      if elapsed > timeout
        raise "Run timed out after #{timeout} seconds"
      end
      
      begin
        response = self.class.get("/threads/#{thread_id}/runs/#{run_id}", headers: @headers)
        run_data = handle_response(response)
        status = run_data['status']
        
        # CRITICAL: Only return on 'completed' - not 'requires_action'
        # After tool outputs, run must be fully completed before next batch
        if status == 'completed'
          add_log('info', "Run #{run_id} fully completed")
          return run_data
        end
        
        if ['failed', 'cancelled', 'expired'].include?(status)
          error_info = run_data['last_error'] || {}
          
          # Extract error details properly
          error_message = if error_info.is_a?(Hash)
            code = error_info['code'] || 'unknown'
            message = error_info['message'] || 'Unknown error'
            "{\"code\":\"#{code}\",\"message\":\"#{message}\"}"
          elsif error_info.is_a?(String)
            error_info
          else
            error_info.to_s
          end
          
          add_log('error', "Run #{run_id} failed with status: #{status}, error: #{error_message}")
          raise "Run failed: #{error_message}"
        end
        
        # Log progress for long-running runs
        if elapsed > 10 && elapsed % 10 < check_interval
          add_log('info', "Run #{run_id} still processing (status: #{status}, elapsed: #{elapsed.round}s)")
        end
        
        sleep check_interval
      rescue => e
        # If it's a network/API error, re-raise for retry logic
        if e.message.include?('OpenAI API Error') || e.message.include?('server_error')
          raise e
        end
        # Otherwise, continue checking
        sleep check_interval
      end
    end
  end
  
  def extract_results_from_requires_action(run_data)
    tool_calls = run_data['required_action']['submit_tool_outputs']['tool_calls']
    results = []
    
    tool_calls.each do |tool_call|
      if tool_call['function'] && tool_call['function']['name'] == 'return_checklist_results'
        function_args = tool_call['function']['arguments']
        if function_args.is_a?(String)
          args = JSON.parse(function_args)
        else
          args = function_args
        end
        
        if args.is_a?(Hash) && args['results']
          results = args['results'] || []
          add_log('info', "Extracted #{results.length} results from function call arguments")
          return results
        end
      end
    end
    
    add_log('warn', "No results found in requires_action tool calls")
    []
  end
  
  def submit_tool_outputs(thread_id, run_id, run_data)
    tool_calls = run_data['required_action']['submit_tool_outputs']['tool_calls']
    tool_outputs = []
    
    tool_calls.each do |tool_call|
      # For return_checklist_results, we don't need to provide output
      # The function call already contains the results in its arguments
      # We just acknowledge it
      tool_outputs << {
        tool_call_id: tool_call['id'],
        output: "acknowledged"
      }
    end
    
    payload = {
      tool_outputs: tool_outputs
    }
    
    response = self.class.post(
      "/threads/#{thread_id}/runs/#{run_id}/submit_tool_outputs",
      headers: @headers,
      body: payload.to_json
    )
    handle_response(response)
  end
  
  def process_checklist_response(thread_id, run_data, checklist_items)
    # This method is called for completed runs only (requires_action is handled earlier)
    # If run is completed, check messages for function calls
    if run_data['status'] == 'completed'
      add_log('info', "Run completed, checking thread messages for function calls...")
      results = extract_results_from_messages(thread_id, checklist_items)
      if results.length > 0
        add_log('info', "Found #{results.length} results from completed run messages")
        return results
      end
    end
    
    # If we still have no results, log warning and return empty
    add_log('warn', "No results found in messages. Run status: #{run_data['status']}")
    []
  end
  
  # Extract results from thread messages (for completed runs)
  def extract_results_from_messages(thread_id, checklist_items)
    begin
      # Get the latest messages from the thread
      response = self.class.get("/threads/#{thread_id}/messages?limit=10", headers: @headers)
      messages_data = handle_response(response)
      messages = messages_data['data'] || []
      
      # Look for assistant messages with function calls
      messages.each do |message|
        next unless message['role'] == 'assistant'
        
        content = message['content'] || []
        content.each do |content_item|
          next unless content_item['type'] == 'function'
          
          function_name = content_item['name']
          if function_name == 'return_checklist_results'
            function_args = content_item['function_call'] || content_item['arguments']
            if function_args.is_a?(String)
              args = JSON.parse(function_args)
            else
              args = function_args
            end
            
            if args.is_a?(Hash) && args['results']
              add_log('info', "Found function call results in message #{message['id']}")
              return args['results'] || []
            end
          end
        end
        
        # Also check tool_calls if present
        tool_calls = message['tool_calls'] || []
        tool_calls.each do |tool_call|
          if tool_call['function'] && tool_call['function']['name'] == 'return_checklist_results'
            function_args = tool_call['function']['arguments']
            if function_args.is_a?(String)
              args = JSON.parse(function_args)
            else
              args = function_args
            end
            
            if args.is_a?(Hash) && args['results']
              add_log('info', "Found tool_call results in message #{message['id']}")
              return args['results'] || []
            end
          end
        end
      end
      
      add_log('warn', "No function call found in thread messages")
      []
    rescue => e
      add_log('error', "Error extracting results from messages: #{e.message}")
      []
    end
  end
  
  # Extract plain text response for debugging (when function call is not made)
  def extract_plain_text_response(thread_id)
    begin
      response = self.class.get("/threads/#{thread_id}/messages?limit=5", headers: @headers)
      messages_data = handle_response(response)
      messages = messages_data['data'] || []
      
      # Find the latest assistant message
      messages.each do |message|
        next unless message['role'] == 'assistant'
        
        content = message['content'] || []
        content.each do |content_item|
          if content_item['type'] == 'text'
            text_value = content_item['text'] && content_item['text']['value']
            return text_value if text_value
          end
        end
      end
      
      nil
    rescue => e
      add_log('error', "Error extracting plain text response: #{e.message}")
      nil
    end
  end

  def handle_response(response)
    if response.success?
      JSON.parse(response.body)
    else
      error_body = begin
        JSON.parse(response.body)
      rescue
        response.body
      end
      
      # Extract error details for better error messages
      error_message = if error_body.is_a?(Hash) && error_body['error']
        error_info = error_body['error']
        "#{error_info['code'] || 'unknown'}: #{error_info['message'] || error_info.to_s}"
      else
        error_body.to_s
      end
      
      raise "OpenAI API Error: #{response.code} - #{error_message}"
    end
  end
  
  # Check if error is retryable
  def is_retryable_error?(error)
    error_message = error.message.downcase
    error_class = error.class.to_s.downcase
    
    # Retry on server errors (5xx)
    return true if error_message.include?('server_error') || error_message.include?('500') || 
                   error_message.include?('502') || error_message.include?('503') || 
                   error_message.include?('504')
    
    # Retry on rate limits
    return true if error_message.include?('rate limit') || error_message.include?('429') ||
                   error_message.include?('too many requests')
    
    # Retry on timeouts
    return true if error_message.include?('timeout') || error_message.include?('timed out')
    
    # Retry on network/connection errors
    return true if error_message.include?('connection') || error_message.include?('network') ||
                   error_message.include?('econnreset') || error_message.include?('econnrefused')
    
    # Retry on service unavailable
    return true if error_message.include?('service unavailable') || error_message.include?('temporary')
    
    # SPECIAL CASE: "Can't add messages while run is active" - retryable with wait
    # This happens if previous run hasn't completed yet
    return true if error_message.include?("can't add messages") && error_message.include?('run') && error_message.include?('active')
    
    # Retry on "no results returned" - model might not have called function
    return true if error_message.include?('no results returned')
    
    # Retry on HTTParty errors (network issues)
    return true if error_class.include?('httparty') && (
      error_message.include?('timeout') || 
      error_message.include?('connection') ||
      error_message.include?('network')
    )
    
    # Don't retry on client errors (4xx except 429 and special cases above)
    return false if error_message.include?('400') || error_message.include?('401') ||
                    error_message.include?('403') || error_message.include?('404')
    
    # Default: retry on unknown errors (better to retry than fail)
    true
  end
  
  # Helper for retries (kept from original, but prefer analyze_checklist_batch_with_retry)
  def retry_request(max_attempts: 3, delay: 1)
    attempts = 0
    begin
      attempts += 1
      yield
    rescue => e
      if attempts < max_attempts
        sleep delay
        retry
      else
        raise e
      end
    end
  end
end
