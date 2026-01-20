class CreateEvaluationChecklistItems < ActiveRecord::Migration[7.1]
  def change
    create_table :evaluation_checklist_items do |t|
      t.references :evaluation, null: false, foreign_key: true
      t.references :checklist_item, null: false, foreign_key: true
      
      t.string :status, null: false # 'Yes', 'No', 'Partial'
      t.text :remarks, null: false

      t.timestamps
    end
    
    add_index :evaluation_checklist_items, [:evaluation_id, :checklist_item_id], unique: true, name: 'idx_eval_checklist_items_unique'
    add_index :evaluation_checklist_items, :status
  end
end
