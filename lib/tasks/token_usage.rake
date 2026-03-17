# Run a single evaluation and print token usage per batch.
# Usage: rails token_usage:run
# Or with specific file: FILE_ID=123 rails token_usage:run
namespace :token_usage do
  desc "Run evaluation and capture token usage (two-pass)"
  task run: :environment do
    scheme = Scheme.find_by(name: "New SDPs") || Scheme.first
    doc_type = DocumentType.find_by(name: "dpr") || DocumentType.first
    raise "No scheme or document type found" unless scheme && doc_type

    assignments = ChecklistItemSchemeAssignment.for_scheme_and_doc_type(scheme.id, doc_type.id)
    checklist_texts = assignments.map { |a| a.checklist_item.item_text }
    raise "No checklist items for #{scheme.name} + #{doc_type.name}" if checklist_texts.empty?

    file = if ENV["FILE_ID"].present?
      UploadedFile.find(ENV["FILE_ID"])
    else
      UploadedFile.where.not(openai_vector_store_id: nil).where(deleted_at: nil).order(created_at: :desc).first
    end
    raise "No uploaded file with vector store found. Upload a file first or set FILE_ID=..." unless file

    puts "=== Token Usage Test ==="
    puts "Scheme: #{scheme.name}, DocType: #{doc_type.name}"
    puts "File: #{file.original_filename} (#{file.file_size_bytes / 1_000_000.0} MB)"
    puts "Checklist items: #{checklist_texts.length}"
    puts ""

    log_accumulator = []
    openai_service = OpenaiService.new(log_accumulator: log_accumulator)
    analysis_response = openai_service.analyze_checklist(
      uploaded_file_id: file.openai_file_id,
      vector_store_id: file.openai_vector_store_id,
      checklist_items: checklist_texts,
      batch_size: 3
    )

    puts "=== Logs (including TOKEN_USAGE) ==="
    log_accumulator.each { |line| puts line }

    puts ""
    puts "=== Token Usage Summary ==="
    token_lines = log_accumulator.grep(/\[TOKEN_USAGE\]/)
    if token_lines.any?
      total_input = 0
      total_output = 0
      token_lines.each do |line|
        puts line
        if line =~ /input=(\d+).*output=(\d+)/
          total_input += Regexp.last_match(1).to_i
          total_output += Regexp.last_match(2).to_i
        end
      end
      puts ""
      puts "TOTAL across all batches: input=#{total_input} output=#{total_output}"
    else
      puts "No [TOKEN_USAGE] lines found. Usage may not be in run response."
    end
  end
end
