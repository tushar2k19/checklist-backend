module Api
  class ChecklistTemplatesController < ApplicationController
    before_action :authenticate_user!

    # GET /api/checklist_templates
    def index
      scheme_id = params[:scheme_id]
      doc_type_id = params[:document_type_id]

      if scheme_id.blank? || doc_type_id.blank?
        return render_error("validation_error", "scheme_id and document_type_id are required", status: :bad_request)
      end

      assignments = ChecklistItemSchemeAssignment.for_scheme_and_doc_type(scheme_id, doc_type_id)

      render_success(
        {
          checklist_items: assignments.map { |a| 
            {
              id: a.checklist_item.id,
              item_text: a.checklist_item.item_text,
              display_order: a.display_order
            }
          }
        },
        message: "Checklist template retrieved successfully"
      )
    end
  end
end


