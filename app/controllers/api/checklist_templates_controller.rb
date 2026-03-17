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
              assignment_id: a.id,
              item_text: a.checklist_item.item_text,
              display_order: a.display_order
            }
          }
        },
        message: "Checklist template retrieved successfully"
      )
    end

    # PATCH /api/checklist_templates/reorder
    def reorder
      scheme_id = params[:scheme_id]
      doc_type_id = params[:document_type_id]
      ordered_item_ids = params[:ordered_item_ids]

      if scheme_id.blank? || doc_type_id.blank?
        return render_error("validation_error", "scheme_id and document_type_id are required", status: :bad_request)
      end

      unless ordered_item_ids.is_a?(Array) && ordered_item_ids.any?
        return render_error("validation_error", "ordered_item_ids must be a non-empty array", status: :bad_request)
      end

      assignments = ChecklistItemSchemeAssignment
        .where(scheme_id: scheme_id, document_type_id: doc_type_id)
        .includes(:checklist_item)

      assignment_by_item_id = assignments.index_by(&:checklist_item_id)

      ordered_item_ids.each_with_index do |item_id, index|
        assignment = assignment_by_item_id[item_id.to_i]
        assignment&.update!(display_order: index)
      end

      render_success(
        { message: "Checklist reordered successfully" },
        message: "Checklist reordered successfully"
      )
    end

    # POST /api/checklist_templates/sync
    # Re-sync editor's items to match guidelines (replaces all assignments with guideline items)
    def sync
      scheme_id = params[:scheme_id]
      doc_type_id = params[:document_type_id]
      item_texts = params[:item_texts]

      if scheme_id.blank? || doc_type_id.blank?
        return render_error("validation_error", "scheme_id and document_type_id are required", status: :bad_request)
      end

      unless item_texts.is_a?(Array) && item_texts.any?
        return render_error("validation_error", "item_texts must be a non-empty array", status: :bad_request)
      end

      scheme = Scheme.find(scheme_id)
      doc_type = DocumentType.find(doc_type_id)

      ChecklistItemSchemeAssignment.transaction do
        ChecklistItemSchemeAssignment
          .where(scheme_id: scheme_id, document_type_id: doc_type_id)
          .destroy_all

        item_texts.each_with_index do |text, index|
          next if text.blank?
          checklist_item = ChecklistItem.find_or_create_by!(item_text: text.strip)
          ChecklistItemSchemeAssignment.create!(
            checklist_item: checklist_item,
            scheme: scheme,
            document_type: doc_type,
            display_order: index
          )
        end
      end

      assignments = ChecklistItemSchemeAssignment.for_scheme_and_doc_type(scheme_id, doc_type_id)

      render_success(
        {
          checklist_items: assignments.map { |a|
            {
              id: a.checklist_item.id,
              assignment_id: a.id,
              item_text: a.checklist_item.item_text,
              display_order: a.display_order
            }
          }
        },
        message: "Checklist synced to guidelines successfully"
      )
    rescue ActiveRecord::RecordInvalid => e
      render_error("validation_error", e.record.errors.full_messages.join(", "), status: :unprocessable_entity)
    end
  end
end


