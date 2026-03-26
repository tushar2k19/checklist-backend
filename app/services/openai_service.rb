class OpenaiService
  include HTTParty
  
  # Base configuration
  base_uri 'https://api.openai.com/v1'

  REWRITE_BATCH_SIZE = 10
  
  def initialize(log_accumulator: nil)
    @api_key = ENV['OPENAI_API_KEY']
    # Assistant ID for the primary checklist evaluation workflow (Assistants API).
    @assistant_id = ENV['Checklist_ASSISTANT_ID']
    # Use dedicated follow-up assistant if set; otherwise fall back to checklist assistant (has file_search; may have function tool but we only send text)
    # Optional override assistant used specifically for the follow-up Q&A flow.
    @followup_assistant_id = ENV['FOLLOWUP_ASSISTANT_ID'].presence || ENV['Checklist_ASSISTANT_ID']
    # Chat/model used by the non-Assistants requests (and/or any model selection logic we apply).
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

  # Log token usage from run response (for cost tracking)
  def log_run_usage(run_data, label = "Run")
    return unless run_data.is_a?(Hash)
    usage = run_data['usage']
    return unless usage.is_a?(Hash)
    # Assistants API v2 may use input_tokens/output_tokens or prompt_tokens/completion_tokens
    pt = usage['input_tokens'] || usage['prompt_tokens']
    ct = usage['output_tokens'] || usage['completion_tokens']
    total = usage['total_tokens']
    if pt || ct || total
      add_log('info', "[TOKEN_USAGE] #{label}: input=#{pt || '?'} output=#{ct || '?'} total=#{total || '?'}")
    end
  end

  # Extract usage hash from run response for persistence. Returns nil if no usage.
  def extract_usage_from_run(run_data)
    return nil unless run_data.is_a?(Hash)
    usage = run_data['usage']
    return nil unless usage.is_a?(Hash)
    pt = usage['input_tokens'] || usage['prompt_tokens']
    ct = usage['output_tokens'] || usage['completion_tokens']
    total = usage['total_tokens']
    return nil unless pt || ct || total
    {
      input_tokens: (pt || 0).to_i,
      output_tokens: (ct || 0).to_i,
      total_tokens: (total || (pt.to_i + ct.to_i)).to_i
    }
  end
  
  # Get all logs as string
  def get_logs
    @log_accumulator ? @log_accumulator.join("\n") : ""
  end

  # Analyze a checklist against a specific file (using vector store)
  # Two-pass strategy:
  # - Pass 1 (retrieval): use file_search to produce status + structured facts
  # - Pass 2 (rewrite): no file_search; convert structured facts into concise final remarks
  #
  # Supports batch processing for better accuracy (defaults to 3 items per batch)
  # Uses SINGLE THREAD for entire evaluation to avoid concurrency issues
  # Includes robust retry logic for failed batches
  def analyze_checklist(uploaded_file_id: nil, vector_store_id:, checklist_items:, batch_size: 5)
    add_log('info', "=== Starting Checklist Analysis ===")
    add_log('info', "Total items: #{checklist_items.length}, Batch size: #{batch_size}")
    
    # Create ONE thread for entire evaluation (reused across all batches)
    thread_id = create_thread(vector_store_id)
    add_log('info', "Created single thread #{thread_id} for entire evaluation")
    
    # Pass 1 (retrieval) - batched, same thread
    add_log('info', "=== Pass 1: retrieval + structured facts ===")
    pass1_results, pass1_input, pass1_output = analyze_checklist_pass1(
      thread_id: thread_id,
      checklist_items: checklist_items,
      batch_size: batch_size
    )

    # Pass 2 (rewrite) - no file_search, rewrite Pass 1 into final concise remarks
    add_log('info', "=== Pass 2: rewrite to final concise remarks (no file_search) ===")
    pass2_results, pass2_input, pass2_output = rewrite_results_pass2(
      pass1_results: pass1_results
    )

    {
      results: pass2_results,
      thread_id: thread_id,
      evaluation_input_tokens: (pass1_input + pass2_input),
      evaluation_output_tokens: (pass1_output + pass2_output)
    }
  end

  # Streaming variant: processes each batch (Pass 1 + Pass 2), yields results via on_batch_complete.
  # Used for progressive evaluation UX where results appear as each batch completes.
  def analyze_checklist_streaming(uploaded_file_id: nil, vector_store_id:, checklist_items:, batch_size: 5, on_batch_complete: nil)
    add_log('info', "=== Starting Checklist Analysis (Streaming) ===")
    add_log('info', "Total items: #{checklist_items.length}, Batch size: #{batch_size}")

    thread_id = create_thread(vector_store_id)
    add_log('info', "Created thread #{thread_id} for streaming evaluation")

    total_input = 0
    total_output = 0
    batches = checklist_items.each_slice(batch_size).to_a
    total_batches = batches.length

    batches.each_with_index do |batch_items, batch_index|
      batch_num = batch_index + 1
      add_log('info', "[STREAMING] Processing batch #{batch_num}/#{total_batches} (#{batch_items.length} items)")

      begin
        # Pass 1: retrieval for this batch only
        batch_result = analyze_checklist_batch_with_retry(
          thread_id,
          batch_items,
          batch_num,
          total_batches,
          max_retries: 3,
          pass_label: 'PASS1'
        )
        pass1_results = batch_result[:results]
        u = batch_result[:usage]
        total_input += u[:input_tokens].to_i if u
        total_output += u[:output_tokens].to_i if u

        # Pass 2: rewrite this batch only (chunk of 1 = this batch)
        pass2_results, p2_in, p2_out = rewrite_results_pass2(pass1_results: pass1_results)
        total_input += p2_in
        total_output += p2_out

        batch_usage = { input_tokens: u&.dig(:input_tokens).to_i + p2_in, output_tokens: u&.dig(:output_tokens).to_i + p2_out }
        on_batch_complete&.call(pass2_results, batch_usage) if on_batch_complete

        if batch_index < batches.length - 1
          add_log('info', "[STREAMING] Waiting 5 seconds before next batch...")
          sleep 5
        end
      rescue => e
        add_log('error', "[STREAMING] Batch #{batch_num} failed: #{e.message}")
        batch_items.each do |item|
          fallback = {
            'item' => item,
            'status' => 'No',
            'remarks' => "Batch failed after retries: #{e.message}"
          }
          on_batch_complete&.call([fallback], { input_tokens: 0, output_tokens: 0 }) if on_batch_complete
        end
        raise e
      end
    end

    {
      thread_id: thread_id,
      evaluation_input_tokens: total_input,
      evaluation_output_tokens: total_output
    }
  end

  def analyze_checklist_pass1(thread_id:, checklist_items:, batch_size:)
    total_input = 0
    total_output = 0
    all_results = []

    batches = checklist_items.each_slice(batch_size).to_a
    total_batches = batches.length

    batches.each_with_index do |batch_items, batch_index|
      batch_num = batch_index + 1
      add_log('info', "[PASS1] Processing batch #{batch_num}/#{total_batches} (#{batch_items.length} items) on thread #{thread_id}")

      begin
        batch_result = analyze_checklist_batch_with_retry(
          thread_id,
          batch_items,
          batch_num,
          total_batches,
          max_retries: 3,
          pass_label: 'PASS1'
        )
        all_results.concat(batch_result[:results])
        u = batch_result[:usage]
        if u
          total_input += u[:input_tokens].to_i
          total_output += u[:output_tokens].to_i
        end

        if batch_index < batches.length - 1
          add_log('info', "[PASS1] Waiting 5 seconds before next batch...")
          sleep 5
        end
      rescue => e
        add_log('error', "[PASS1] Batch #{batch_num} failed after all retries: #{e.message}")
        add_log('error', "[PASS1] Error class: #{e.class}, Backtrace: #{e.backtrace.first(3).join(', ')}")

        batch_items.each do |item|
          all_results << {
            'item' => item,
            'status' => 'No',
            'key_points' => [],
            'location_hints' => [],
            'missing_points' => [],
            'not_found_reason' => "Pass 1 failed after multiple retries: #{e.message}",
            'remarks' => ''
          }
        end
      end
    end

    [all_results, total_input, total_output]
  end

  def rewrite_results_pass2(pass1_results:)
    # Chunk pass1 results to keep prompts bounded; rewrite is cheap but can still be large.
    total_input = 0
    total_output = 0
    final_results = []

    rewrite_thread_id = create_thread(nil)
    chunks = pass1_results.each_slice(REWRITE_BATCH_SIZE).to_a
    total_chunks = chunks.length

    chunks.each_with_index do |chunk, idx|
      chunk_num = idx + 1
      add_log('info', "[PASS2] Rewriting chunk #{chunk_num}/#{total_chunks} (#{chunk.length} items) on thread #{rewrite_thread_id}")

      prompt = build_rewrite_prompt(chunk, chunk_num, total_chunks)
      send_message(rewrite_thread_id, prompt)
      run_id = create_rewrite_run(rewrite_thread_id)
      run_data = wait_for_run_completion(rewrite_thread_id, run_id, timeout: 180)
      log_run_usage(run_data, "PASS2 chunk #{chunk_num}/#{total_chunks}")
      usage = extract_usage_from_run(run_data)

      # Handle requires_action for rewrite run
      if run_data['status'] == 'requires_action'
        results = extract_results_from_requires_action(run_data)
        add_log('info', "[PASS2] requires_action: extracted #{results.length} results from function call args")
        submit_tool_outputs(rewrite_thread_id, run_id, run_data)
        completed_run_data = wait_for_run_to_fully_complete(rewrite_thread_id, run_id, timeout: 180)
        log_run_usage(completed_run_data, "PASS2 chunk #{chunk_num}/#{total_chunks} (after tool outputs)")
        usage = extract_usage_from_run(completed_run_data) if completed_run_data
        final_results.concat(results)
      else
        results = process_checklist_response(rewrite_thread_id, run_data, chunk.map { |r| r['item'] })
        final_results.concat(results)
      end

      if usage
        total_input += usage[:input_tokens].to_i
        total_output += usage[:output_tokens].to_i
      end
    end

    [final_results, total_input, total_output]
  end

  # Ask a follow-up question on a checklist item using a dedicated assistant.
  # The first message injects checklist context; subsequent messages include
  # only the user question and rely on thread history.
  def ask_followup_question(evaluation_checklist_item:, vector_store_id:, message:, thread_id: nil)
    raise 'No assistant configured: set FOLLOWUP_ASSISTANT_ID or Checklist_ASSISTANT_ID' if @followup_assistant_id.blank?
    raise 'vector_store_id is required for follow-up questions' if vector_store_id.blank?

    is_new_thread = thread_id.blank?
    active_thread_id = thread_id.presence || create_thread(vector_store_id)

    prompt = if is_new_thread
      build_followup_initial_prompt(evaluation_checklist_item: evaluation_checklist_item, question: message)
    else
      message
    end

    send_message(active_thread_id, prompt)
    run_id = create_followup_run(active_thread_id)
    run_data = wait_for_run_completion(active_thread_id, run_id, timeout: 240)
    log_run_usage(run_data, "Follow-up question")
    followup_usage = extract_usage_from_run(run_data)

    answer = extract_latest_assistant_text(active_thread_id)
    if answer.blank?
      raise 'No follow-up response received from assistant'
    end
    normalized = normalize_followup_response(answer)

    {
      answer: normalized[:text],
      status: normalized[:status],
      thread_id: active_thread_id,
      is_new_thread: is_new_thread,
      input_tokens: followup_usage&.dig(:input_tokens).to_i,
      output_tokens: followup_usage&.dig(:output_tokens).to_i,
      total_tokens: followup_usage&.dig(:total_tokens).to_i
    }
  end

  def fetch_thread_messages(thread_id:, limit: 50)
    response = self.class.get("/threads/#{thread_id}/messages?limit=#{limit}", headers: @headers)
    messages_data = handle_response(response)
    messages = messages_data['data'] || []

    messages.reverse.map do |message|
      raw_content = extract_message_text_content(message)
      normalized = message['role'] == 'assistant' ? normalize_followup_response(raw_content) : { text: raw_content, status: nil }
      {
        role: message['role'],
        content: normalized[:text],
        status: normalized[:status],
        created_at: Time.at(message['created_at']).iso8601
      }
    end
  end
  
  # Analyze a single batch with retry logic
  # Now accepts thread_id instead of vector_store_id to reuse same thread
  def analyze_checklist_batch_with_retry(thread_id, checklist_items, batch_num, total_batches, max_retries: 3, pass_label: nil)
    attempt = 0
    last_error = nil
    
    while attempt < max_retries
      attempt += 1
      begin
        prefix = pass_label ? "[#{pass_label}] " : ""
        add_log('info', "#{prefix}Batch #{batch_num}: Attempt #{attempt}/#{max_retries} on thread #{thread_id}")
        
        batch_result = analyze_checklist_batch(thread_id, checklist_items, batch_num, total_batches)
        
        add_log('info', "#{prefix}Batch #{batch_num}: Successfully completed on attempt #{attempt}")
        return batch_result
        
      rescue => e
        last_error = e
        is_retryable = is_retryable_error?(e)
        
        add_log('warn', "#{prefix}Batch #{batch_num}: Attempt #{attempt} failed: #{e.message}")
        add_log('warn', "#{prefix}Error class: #{e.class}, Retryable: #{is_retryable}")
        
        if attempt < max_retries && is_retryable
          # Longer backoff for large file processing: 10s, 20s, 40s (capped at 45s)
          wait_time = [10 * (2 ** (attempt - 1)), 45].min
          add_log('warn', "#{prefix}Batch #{batch_num}: Retrying in #{wait_time}s... (attempt #{attempt + 1}/#{max_retries})")
          sleep wait_time
        else
          if !is_retryable
            add_log('error', "#{prefix}Batch #{batch_num}: Non-retryable error, stopping retries")
          else
            add_log('error', "#{prefix}Batch #{batch_num}: Max retries (#{max_retries}) reached")
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
      log_run_usage(run_data, "Batch #{batch_num}/#{total_batches} (after run completion)")
      batch_usage = extract_usage_from_run(run_data)

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
          # Usage is only populated when run is in terminal state; at requires_action it was nil
          add_log('info', "Waiting for run to fully complete after tool outputs submission...")
          # Some runs can take longer to transition from requires_action -> completed after tool output submission.
          # Keep this bounded; if it times out we will cancel the run to unblock the thread before retrying.
          completed_run_data = wait_for_run_to_fully_complete(thread_id, run_id, timeout: 180)
          log_run_usage(completed_run_data, "Batch #{batch_num}/#{total_batches} (after tool outputs)")
          batch_usage = extract_usage_from_run(completed_run_data) if completed_run_data
          add_log('info', "Run fully completed, safe to proceed to next batch")

          # Results are already extracted, return them with usage from completed run
          return {
            results: results,
            thread_id: thread_id,
            usage: batch_usage
          }
        else
          add_log('warn', "No results found in requires_action, submitting tool outputs and checking messages...")
          submit_tool_outputs(thread_id, run_id, run_data)
          # Wait for FULL completion after submitting tool outputs (must be 'completed', not 'requires_action')
          run_data = wait_for_run_to_fully_complete(thread_id, run_id, timeout: 420)
          log_run_usage(run_data, "Batch #{batch_num}/#{total_batches} (after tool outputs)")
          batch_usage = extract_usage_from_run(run_data)
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
      
      # Return results, thread_id, and usage for analytics
      {
        results: results,
        thread_id: thread_id,
        usage: batch_usage
      }
    rescue => e
      add_log('error', "Batch Analysis Failed: #{e.message}")
      add_log('error', "Error class: #{e.class}")
      # If we timed out, try to cancel the active run so the thread is not stuck in "run active" state.
      # This prevents subsequent retries from failing with "Can't add messages while a run is active."
      if e.message.to_s.downcase.include?('timed out') && defined?(run_id) && run_id
        begin
          add_log('warn', "Attempting to cancel run #{run_id} after timeout...")
          cancel_run(thread_id, run_id)
        rescue => cancel_err
          add_log('warn', "Failed to cancel run #{run_id}: #{cancel_err.message}")
        end
      end
      raise e
    end
  end
  
  private

  def create_thread(vector_store_id = nil)
    payload = {}
    if vector_store_id.present?
      payload[:tool_resources] = {
        file_search: {
          vector_store_ids: [vector_store_id]
        }
      }
    end
    
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

  def build_followup_initial_prompt(evaluation_checklist_item:, question:)
    checklist_item = evaluation_checklist_item.checklist_item
    <<~PROMPT
      You are answering follow-up questions for a DPR checklist review.
      Use only information from the current thread conversation and the DPR document attached to this thread via file search.
      Do not use outside knowledge.
      If requested information (including a specific page or section) is not present in the document, state that clearly and do not invent content.

      Checklist item: #{checklist_item.item_text}
      Status: #{evaluation_checklist_item.status}
      Remarks: #{evaluation_checklist_item.remarks}

      User question: #{question}
    PROMPT
  end

  def create_followup_run(thread_id)
    payload = {
      assistant_id: @followup_assistant_id,
      tools: [
        { type: 'file_search' }
      ]
    }

    response = self.class.post(
      "/threads/#{thread_id}/runs",
      headers: @headers,
      body: payload.to_json
    )
    handle_response(response)['id']
  end

  def extract_latest_assistant_text(thread_id)
    response = self.class.get("/threads/#{thread_id}/messages?limit=10", headers: @headers)
    messages_data = handle_response(response)
    messages = messages_data['data'] || []

    assistant_message = messages.find { |message| message['role'] == 'assistant' }
    return nil unless assistant_message

    extract_message_text_content(assistant_message)
  end

  def extract_message_text_content(message)
    content = message['content'] || []
    text_chunks = content.filter_map do |content_item|
      next unless content_item['type'] == 'text'
      text = content_item.dig('text', 'value')
      text if text.present?
    end

    text_chunks.join("\n").strip
  end

  # Normalize function-call-like text responses into plain answer format.
  # Example input:
  # return_checklist_results({"Item":{"Status":"Yes","Remarks":"..."}})
  # Output:
  # { text: "Status: Yes\n\nRemarks: ...", status: "Yes" }
  def normalize_followup_response(raw_text)
    text = raw_text.to_s.strip
    return { text: text, status: nil } if text.blank?

    # Check if this is a function call pattern
    if text.include?('return_checklist_results(')
      json_payload = extract_return_checklist_results_payload(text)
      
      # If we found a function call but couldn't extract valid JSON (e.g., empty array)
      # provide a user-friendly message
      if json_payload.blank?
        return { 
          text: "I apologize, but I couldn't find the specific information you're looking for in the document. Could you please rephrase your question or provide more context?",
          status: nil 
        }
      end

      begin
        parsed = JSON.parse(json_payload)
        return { text: text, status: nil } unless parsed.is_a?(Hash)

        # Shape A: {"Status":"Yes","Remarks":"..."}
        if parsed.key?('Status') || parsed.key?('Remarks')
          status = parsed['Status'].to_s.strip
          remarks = parsed['Remarks'].to_s.strip
          return { text: text, status: nil } if status.blank? && remarks.blank?

          normalized_text = +""
          if status.present?
            normalized_text << "Status: #{status}\n"
          end
          normalized_text << "Remarks:\n#{remarks}" if remarks.present?

          clean_status = %w[Yes No Partial].include?(status) ? status : nil
          return { text: normalized_text.strip, status: clean_status }
        end

        # Shape B: {"Item Name":{"Status":"Yes","Remarks":"..."}}
        first_key, first_value = parsed.first
        return { text: text, status: nil } unless first_value.is_a?(Hash)

        status = first_value['Status'].to_s.strip
        remarks = first_value['Remarks'].to_s.strip
        return { text: text, status: nil } if status.blank? && remarks.blank?

        normalized_text = +""
        if first_key.present?
          normalized_text << "Item: #{first_key}\n"
        end
        if status.present?
          normalized_text << "Status: #{status}\n"
        end
        if remarks.present?
          normalized_text << "Remarks:\n#{remarks}"
        end

        clean_status = %w[Yes No Partial].include?(status) ? status : nil
        { text: normalized_text.strip, status: clean_status }
      rescue JSON::ParserError
        # If JSON parsing fails but we detected a function call, provide a friendly message
        { 
          text: "I apologize, but I encountered an issue processing the response. Could you please try rephrasing your question?",
          status: nil 
        }
      end
    else
      # Normal text response - return as is
      { text: text, status: nil }
    end
  end

  def extract_return_checklist_results_payload(text)
    marker = 'return_checklist_results('
    marker_index = text.index(marker)
    return nil unless marker_index

    start_index = marker_index + marker.length
    depth = 0
    payload_start = nil
    bracket_type = nil  # Will be either '{' or '['

    i = start_index
    while i < text.length
      ch = text[i]
      
      # Handle both objects {} and arrays []
      if ch == '{' || ch == '['
        if payload_start.nil?
          payload_start = i
          bracket_type = ch
        end
        depth += 1
      elsif (ch == '}' && bracket_type == '{') || (ch == ']' && bracket_type == '[')
        depth -= 1 if depth > 0
        if depth == 0 && payload_start
          payload = text[payload_start..i]
          # Special case: If it's an empty array or empty object, return nil
          stripped_payload = payload.strip
          return nil if stripped_payload == '[]' || stripped_payload == '{}'
          return payload
        end
      elsif ch == ')' && payload_start.nil?
        # Function call with no payload: return_checklist_results()
        return nil
      end
      i += 1
    end

    # If we reached here and found a payload_start but never closed it,
    # the function call is malformed
    nil
  end
  
  def build_checklist_prompt(checklist_items, batch_num = nil, total_batches = nil)
    items_list = checklist_items.map.with_index(1) { |item, i| "#{i}. #{item}" }.join("\n")
    batch_info = batch_num && total_batches ? "\nBATCH: #{batch_num} of #{total_batches}." : ""
    
    <<~PROMPT
      PASS 1 (Retrieval): Evaluate ONLY the checklist items listed below for this batch, using ONLY the document available in this thread's vector store.
      #{batch_info}

      CHECKLIST ITEMS (analyze all):
      #{items_list}

      For each item:
      - Decide status: Yes / Partial / No
      - Do NOT write long prose. Instead, return structured fields:
        - key_points: 2-5 concise factual bullets grounded in the document
        - location_hints: page/section/chapter hints when available
        - missing_points (Partial only): what is missing
        - not_found_reason (No only): concise reason
      - Before marking "No", try at least 2 distinct keyword/synonym searches for that item.
      - Do NOT include quotes. Do NOT mention file_search.

      MANDATORY: Return ONLY via the 'return_checklist_results' function (no conversational text).
    PROMPT
  end

  def build_rewrite_prompt(pass1_chunk, chunk_num, total_chunks)
    payload = JSON.pretty_generate({ results: pass1_chunk })
    <<~PROMPT
      PASS 2 (Rewrite): Convert the structured Pass 1 results into final readable remarks for the UI (Markdown format).
      CHUNK: #{chunk_num} of #{total_chunks}.

      Requirements:
      - Output MUST be visually readable in a plain-text UI (newlines preserved).
      - Each bullet MUST be on its own line (use newline characters).
      - If you include multiple points, NEVER put them on one line separated by semicolons.
      - Prefer 2-6 bullets max.
      - Highlight key terms/numbers/amounts/keywords/locations (and other important information) by wrapping them in **double-asterisks** (e.g. **₹12.5 Cr**, **3 months**, **10%**, **Missing**, **Provided**, **Year 1**, **Month 24**, **page 23**, **MHA**, **NESIDS**, **Mizoram**, **North-East**, **Nagaland**, etc ).
      - If status is No: include a single-line reason (can be 1-2 bullets), don't over-explain.
      - Do NOT use file_search or any external knowledge.
      - Do NOT add evidence quotes. Only include location hints if present.
      - Keep status unchanged.

      Input (Pass 1 structured results JSON):
      #{payload}

      Output:
      Return ONLY via return_checklist_results with results[] containing: item, status, remarks.
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
                      # Pass 1 can return structured fields; Pass 2 returns only remarks.
                      remarks: { type: "string" },
                      key_points: { type: "array", items: { type: "string" } },
                      location_hints: { type: "array", items: { type: "string" } },
                      missing_points: { type: "array", items: { type: "string" } },
                      not_found_reason: { type: "string" }
                      },
                      required: ["item", "status"]
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

  def create_rewrite_run(thread_id)
    payload = {
      assistant_id: @assistant_id,
      tools: [
        {
          type: "function",
          function: {
            name: "return_checklist_results",
            description: "Return rewritten checklist results",
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
  # Wait for run to FULLY complete - ONLY returns on 'completed' status
  # Used after submitting tool outputs to ensure run is completely done.
  #
  # NOTE: Some runs can take time to transition from requires_action -> completed,
  # especially on large PDFs with heavy file_search. Keep this bounded; callers may cancel on timeout.
  def wait_for_run_to_fully_complete(thread_id, run_id, timeout: 180)
    start_time = Time.zone.now
    check_interval = 2 # Check every 2 seconds
    last_resubmit_at = nil
    
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

        # If OpenAI keeps the run in requires_action after tool output submission, re-submit tool outputs
        # idempotently to help the run transition. This addresses intermittent stuck requires_action runs.
        if status == 'requires_action'
          now = Time.zone.now
          should_resubmit = last_resubmit_at.nil? || (now - last_resubmit_at) >= 15
          if should_resubmit
            begin
              add_log('warn', "Run #{run_id} still requires_action; re-submitting tool outputs to unblock (elapsed: #{elapsed.round}s)")
              submit_tool_outputs(thread_id, run_id, run_data)
              last_resubmit_at = now
            rescue => resubmit_err
              add_log('warn', "Re-submit tool outputs failed for run #{run_id}: #{resubmit_err.message}")
              last_resubmit_at = now
            end
          end
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

  # Cancel an active run to unblock a thread.
  def cancel_run(thread_id, run_id)
    response = self.class.post("/threads/#{thread_id}/runs/#{run_id}/cancel", headers: @headers)
    handle_response(response)
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
    
    # If we still have no results, attempt to parse plain JSON text fallback.
    add_log('warn', "No results found in messages. Run status: #{run_data['status']}")
    plain_text = extract_plain_text_response(thread_id)
    parsed = parse_results_from_plain_json(plain_text)
    return parsed if parsed.any?
    []
  end

  def parse_results_from_plain_json(text)
    return [] if text.blank?
    trimmed = text.to_s.strip
    return [] unless trimmed.start_with?('{') || trimmed.start_with?('[')

    begin
      parsed = JSON.parse(trimmed)
      if parsed.is_a?(Hash) && parsed['results'].is_a?(Array)
        add_log('warn', "Parsed results from plain JSON text fallback")
        return parsed['results']
      end
      []
    rescue JSON::ParserError
      []
    end
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
