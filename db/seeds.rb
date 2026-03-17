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

# PM-DevINE DPR checklist (33 items) – Ref. Para 9.5 of the Guidelines
# See docs/PM_DEVINE_DPR_CHECKLIST.md
pm_devine_dpr_items = [
  "Approval of Concept Note from MDONER (Minutes of EIMC)",
  "Compliance with the comments (if any) of the concerned line department and conditions specified by EIMC (if any) at time of selection of project",
  "Endorsement of DPR by SLEC and submission of project proposal to MDONER (minutes of SLEC to be enclosed)",
  "Project Profile",
  "Expected beneficiaries and socioeconomic impact",
  "Alignment of proposed project with the focus areas indicated under the scheme guidelines",
  "Timeline for implementation",
  "Structured roadmap covering approvals, construction, and operational phase including contingencies via PERT Charts",
  "Sustainability Plan",
  "Use of energy efficient solutions for sustainability",
  "Mechanism for O&M (after project completion)",
  "O&M Mechanism identifying responsible agencies",
  "Financial Plan for operational sustainability (Ownership, revenue model, and operational responsibilities post MDONER funding period.)",
  "Cost Estimates, clearly indicating the basis for unit costs",
  "All Sources of funding for the project (Mandatory disclosure on whether Private Investment or PPP has been explored; if feasible, a plan for leveraging VGF/co-funding mechanisms should be detailed)",
  "Location(s) of project with geo-coordinates",
  "Satellite image / photograph of project site with GIS based accessibility study for evaluation of connectivity",
  "Alignment with Gati Shakti Master Plan to demonstrate convergence",
  "Compliance with guidelines of concerned line department",
  "Output-Outcome framework with KPIs for monitoring the project to be provided as per the sectoral indicators mentioned under Point C of Annexure E of the Guidelines",
  "Provision for project evaluation(s)",
  "Report of the institute of repute on the techno-economic vetting of DPR, along with the Executive Summary of the DPR",
  "Statutory Clearances, as applicable: Forest & Environment",
  "Statutory Clearances, as applicable: Town and Country Planning",
  "Statutory Clearances, as applicable: Industries",
  "Availability of encumbrance-free land for the project",
  "Certification that costs proposed is as per the latest applicable Schedule of Rates",
  "Non-duplication Certificate, duly endorsed to the concerned line department in the States, and concerned line Ministry at the Centre, within whose purview the project falls",
  "Identification of Risks and Mitigation Measures: Technical Risks",
  "Identification of Risks and Mitigation Measures: Administrative Risk",
  "Identification of Risks and Mitigation Measures: Environmental Risk",
  "Identification of Risks and Mitigation Measures: Risk due to natural disaster",
  "Identification of Risks and Mitigation Measures: Operational Risk"
]
pm_devine_dpr_objects = pm_devine_dpr_items.map { |text| ChecklistItem.create!(item_text: text) }

puts "Seeding Template Assignments..."
# PM-DevINE uses dedicated 33-item DPR checklist; other schemes use common items.
# Concept Note for all schemes uses first 5 common items.

dpr_type = DocumentType.find_by(name: 'dpr')
concept_note_type = DocumentType.find_by(name: 'concept_note')
pm_devine_scheme = Scheme.find_by(name: 'PM-DevINE')

Scheme.all.each do |scheme|
  if scheme.id == pm_devine_scheme.id
    # PM-DevINE + DPR: 33 dedicated checklist items
    pm_devine_dpr_objects.each_with_index do |item, index|
      ChecklistItemSchemeAssignment.create!(
        checklist_item: item,
        scheme: scheme,
        document_type: dpr_type,
        display_order: index + 1,
        is_active: true
      )
    end
  else
    # Other schemes + DPR: common items
    checklist_item_objects.each_with_index do |item, index|
      ChecklistItemSchemeAssignment.create!(
        checklist_item: item,
        scheme: scheme,
        document_type: dpr_type,
        display_order: index + 1,
        is_active: true
      )
    end
  end

  # Concept Note: first 5 common items for all schemes (including PM-DevINE)
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
