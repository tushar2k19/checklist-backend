class DocumentType < ApplicationRecord
  # Associations
  has_many :checklist_item_scheme_assignments, dependent: :destroy
  has_many :evaluations, dependent: :restrict_with_error

  # Validations
  validates :name, presence: true, uniqueness: true

  # Scopes
  scope :ordered, -> { order(name: :asc) }
end


