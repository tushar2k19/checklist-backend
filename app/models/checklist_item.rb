class ChecklistItem < ApplicationRecord
  # Associations
  has_many :checklist_item_scheme_assignments, dependent: :destroy
  has_many :evaluation_checklist_items, dependent: :restrict_with_error
  has_many :evaluations, through: :evaluation_checklist_items

  # Validations
  validates :item_text, presence: true

  # Scopes
  scope :ordered, -> { order(id: :asc) }
  
  # Fulltext search
  def self.search(query)
    return all if query.blank?
    where("MATCH(item_text) AGAINST(? IN BOOLEAN MODE)", query)
  end
end


