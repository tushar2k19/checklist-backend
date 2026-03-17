module Api
  class ChecklistItemsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_checklist_item, only: [:update]

    # POST /api/checklist_items
    def create
      scheme_id = params[:scheme_id]
      doc_type_id = params[:document_type_id]
      item_text = params[:item_text]

      if scheme_id.blank? || doc_type_id.blank?
        return render_error("validation_error", "scheme_id and document_type_id are required", status: :bad_request)
      end

      if item_text.blank?
        return render_error("validation_error", "item_text is required", status: :bad_request)
      end

      scheme = Scheme.find(scheme_id)
      doc_type = DocumentType.find(doc_type_id)

      checklist_item = ChecklistItem.create!(item_text: item_text.strip)

      max_order = ChecklistItemSchemeAssignment
        .where(scheme_id: scheme_id, document_type_id: doc_type_id)
        .maximum(:display_order) || -1

      assignment = ChecklistItemSchemeAssignment.create!(
        checklist_item: checklist_item,
        scheme: scheme,
        document_type: doc_type,
        display_order: max_order + 1
      )

      render_success(
        {
          checklist_item: {
            id: checklist_item.id,
            assignment_id: assignment.id,
            item_text: checklist_item.item_text,
            display_order: assignment.display_order
          }
        },
        message: "Checklist item created successfully",
        status: :created
      )
    rescue ActiveRecord::RecordInvalid => e
      render_error("validation_error", e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    rescue ActiveRecord::RecordNotFound, ActiveRecord::RecordNotUnique
      render_error("validation_error", "Invalid scheme or document type", status: :unprocessable_entity)
    end

    # PATCH /api/checklist_items/:id
    def update
      item_text = params[:item_text]

      if item_text.blank?
        return render_error("validation_error", "item_text is required", status: :bad_request)
      end

      @checklist_item.update!(item_text: item_text.strip)

      render_success(
        {
          checklist_item: {
            id: @checklist_item.id,
            item_text: @checklist_item.item_text
          }
        },
        message: "Checklist item updated successfully"
      )
    rescue ActiveRecord::RecordInvalid => e
      render_error("validation_error", e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    end

    private

    def set_checklist_item
      @checklist_item = ChecklistItem.find(params[:id])
    end
  end
end
