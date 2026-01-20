# Clear existing data (optional, be careful in production)
puts "Cleaning up existing data..."
EvaluationChecklistItem.destroy_all
Evaluation.destroy_all
ChecklistItemSchemeAssignment.destroy_all
ChecklistItem.destroy_all
Scheme.destroy_all
DocumentType.destroy_all

puts "Seeding Schemes..."
schemes = [
  'SoNEC', 
  'NESIDS - OTRI', 
  'NESIDS - Roads', 
  'PM-DevINE', 
  'SDP', 
  'BTC', 
  'KAATC', 
  'DHATC', 
  'New SDPs', 
  'NEEDS', 
  'EAP (ELEMENT)', 
  'Non-Scheme Expenditure'
]

schemes.each do |name|
  Scheme.create!(name: name)
end

puts "Seeding Document Types..."
doc_types = ['dpr', 'concept_note']
doc_types.each do |name|
  DocumentType.create!(name: name)
end

puts "Seeding Checklist Items..."
# Common items used across most schemes
common_items = [
  "Project rationale and the intended beneficiaries",
  "Socio-economic benefits of the project",
  "Alignment with scheme guidelines and focus areas",
  "Output-Outcome framework with KPIs for monitoring",
  "SDG or other indices that the KPIs will impact and how",
  "Total Project Cost for the Project",
  "Convergence plan with other ongoing government interventions",
  "Prioritized list of projects, duly signed by the chief secretary",
  "Alignment with Gati Shakti Master Plan",
  "Sustainability plan and environmental considerations",
  "Mechanism for O&M (during and after project life)",
  "Timeline for implementation and the plan",
  "Statuatory Clearances for the Forest and Environment",
  "Certificates of availability of encumbrance-free land",
  "Certification that costs proposed is as per latest schedule of rates",
  "Non-duplication certificate"
]

checklist_item_objects = []
common_items.each do |text|
  checklist_item_objects << ChecklistItem.create!(item_text: text)
end

puts "Seeding Template Assignments..."
# For demonstration, assign all common items to all schemes + dpr
# In reality, this would be more granular based on specific scheme requirements

dpr_type = DocumentType.find_by(name: 'dpr')
concept_note_type = DocumentType.find_by(name: 'concept_note')

Scheme.all.each do |scheme|
  # Assign to DPR
  checklist_item_objects.each_with_index do |item, index|
    ChecklistItemSchemeAssignment.create!(
      checklist_item: item,
      scheme: scheme,
      document_type: dpr_type,
      display_order: index + 1,
      is_active: true
    )
  end
  
  # Assign first 5 items to Concept Note (simpler checklist)
  checklist_item_objects.take(5).each_with_index do |item, index|
    ChecklistItemSchemeAssignment.create!(
      checklist_item: item,
      scheme: scheme,
      document_type: concept_note_type,
      display_order: index + 1,
      is_active: true
    )
  end
end

puts "Seeding Completed Successfully!"
