class ChecklistItemSchemeAssignment < ApplicationRecord
  belongs_to :checklist_item
  belongs_to :scheme
  belongs_to :document_type

  # Validations
  validates :checklist_item_id, uniqueness: { scope: [:scheme_id, :document_type_id], message: "is already assigned to this scheme and document type" }
  validates :display_order, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  # Scopes
  scope :active, -> { where(is_active: true) }
  scope :ordered, -> { order(display_order: :asc) }
  
  def self.for_scheme_and_doc_type(scheme_id, doc_type_id)
    where(scheme_id: scheme_id, document_type_id: doc_type_id)
      .active
      .ordered
      .includes(:checklist_item)
  end
end


