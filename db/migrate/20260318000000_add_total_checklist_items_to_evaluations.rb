# frozen_string_literal: true

class AddTotalChecklistItemsToEvaluations < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluations, :total_checklist_items, :integer
  end
end
