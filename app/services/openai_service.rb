class OpenaiService
  include HTTParty
  
  # Base configuration
  base_uri 'https://api.openai.com/v1'
  
  def initialize
    @api_key = ENV['OPENAI_API_KEY']
    @assistant_id = ENV['OPENAI_ASSISTANT_ID']
    @model = ENV['OPENAI_MODEL'] || 'gpt-4o'
    
    @headers = {
      'Authorization' => "Bearer #{@api_key}",
      'Content-Type' => 'application/json',
      'OpenAI-Beta' => 'assistants=v2'
    }
  end

  # Analyze a checklist against a specific file (using vector store)
  def analyze_checklist(uploaded_file_id: nil, vector_store_id:, checklist_items:)
    Rails.logger.info "=== Starting Checklist Analysis ==="
    
    begin
      # Step 1: Create a temporary thread for this analysis
      thread_id = create_thread(vector_store_id)
      
      # Step 2: Build the prompt with multi-angle instructions and examples
      prompt = build_checklist_prompt(checklist_items)
      
      # Step 3: Send message
      send_message(thread_id, prompt)
      
      # Step 4: Create run
      run_id = create_checklist_run(thread_id)
      
      # Step 5: Wait for completion
      start_time = Time.now
      run_data = wait_for_run_completion(thread_id, run_id, timeout: 300)
      
      # Step 6: Process results
      results = process_checklist_response(thread_id, run_data, checklist_items)
      
      # Return BOTH results and thread_id
      {
        results: results,
        thread_id: thread_id
      }
      
    rescue => e
      Rails.logger.error "Analysis Failed: #{e.message}"
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
  
  def build_checklist_prompt(checklist_items)
    items_list = checklist_items.map.with_index(1) { |item, i| "#{i}. #{item}" }.join("\n")
    
    <<~PROMPT
      You are a specialized DPR (Detailed Project Report) Compliance Auditor.
      
      CORE RULE:
      Analyze ONLY the document provided in the vector store for this thread. 
      Ignore all previous knowledge of state projects or other DPRs. If the document is a general document like a proposal, random pdf or any non-DPR file, mark all items as "No" and state "Document is not a valid DPR" in remarks.

      CHECKLIST FOR EVALUATION:
      #{items_list}

      INSTRUCTIONS FOR REMARKS (Multi-Angle):
      - If "Yes": Provide a 100+ word technical summary. Mention specific values, departments, or dates found in the text.
      - If "Partial": Clearly state what is present and what is missing. Why is it incomplete?
      - If "No": Explicitly state: "Information regarding [Item] was not found in the provided document."

      EXAMPLES OF QUALITY ANALYSIS:
      - Angle 1 (Technical/Financial): "Yes. The report specifies a total project cost of ₹45.6 Cr on page 12, with a clear breakdown into Civil (₹30Cr) and Electrical (₹15.6Cr) components. Implementation is scheduled over 18 months...."
      - Angle 2 (Administrative/Compliance): "No. While the document mentions environmental impact, it lacks the mandatory 'No Objection Certificate' from the State Forest Department as required by the guidelines...."
      - Angle 3 (Strategic/Rationale): "Partial. The DPR identifies 'unemployed youth' as beneficiaries but fails to provide the specific KPI targets or socio-economic impact metrics for the 2025-26 period (on page 37)...."

      MANDATORY: You MUST return your findings by calling the 'return_checklist_results' function.
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
  
  def wait_for_run_completion(thread_id, run_id, timeout: 120)
    start_time = Time.now
    
    loop do
      if Time.now - start_time > timeout
        raise "Run timed out after #{timeout} seconds"
      end
      
      response = self.class.get("/threads/#{thread_id}/runs/#{run_id}", headers: @headers)
      run_data = handle_response(response)
      status = run_data['status']
      
      return run_data if ['completed', 'requires_action'].include?(status)
      raise "Run failed: #{run_data['last_error']}" if ['failed', 'cancelled', 'expired'].include?(status)
      
      sleep 1
    end
  end
  
  def process_checklist_response(thread_id, run_data, checklist_items)
    if run_data['status'] == 'requires_action'
      tool_calls = run_data['required_action']['submit_tool_outputs']['tool_calls']
      
      tool_calls.each do |tool_call|
        if tool_call['function']['name'] == 'return_checklist_results'
          args = JSON.parse(tool_call['function']['arguments'])
          return args['results']
        end
      end
    end
    
    # Fallback if no function call (shouldn't happen with strict prompting)
    []
  end

  def handle_response(response)
    if response.success?
      JSON.parse(response.body)
    else
      raise "OpenAI API Error: #{response.code} - #{response.body}"
    end
  end
  
  # Helper for retries (kept from original)
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
