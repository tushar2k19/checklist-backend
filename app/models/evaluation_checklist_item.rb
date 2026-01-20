class EvaluationChecklistItem < ApplicationRecord
  belongs_to :evaluation
  belongs_to :checklist_item

  # Validations
  validates :status, presence: true, inclusion: { in: %w[Yes No Partial] }
  validates :remarks, presence: true
  validates :checklist_item_id, uniqueness: { scope: :evaluation_id }

  # Enums (using strings directly to match OpenAI output, but could map to integers if preferred)
  # Keeping as simple validation for now since db stores strings 'Yes', 'No', 'Partial'

  # Scopes
  scope :compliant, -> { where(status: 'Yes') }
  scope :non_compliant, -> { where(status: 'No') }
  scope :partial, -> { where(status: 'Partial') }
end


