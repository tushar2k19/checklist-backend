class CreateChecklistItemSchemeAssignments < ActiveRecord::Migration[7.1]
  def change
    create_table :checklist_item_scheme_assignments do |t|
      t.references :checklist_item, null: false, foreign_key: true
      t.references :scheme, null: false, foreign_key: true
      t.references :document_type, null: false, foreign_key: true
      t.integer :display_order, default: 0
      t.boolean :is_active, default: true

      t.timestamps
    end
    
    add_index :checklist_item_scheme_assignments, [:checklist_item_id, :scheme_id, :document_type_id], unique: true, name: 'idx_checklist_assignments_unique'
    add_index :checklist_item_scheme_assignments, [:scheme_id, :document_type_id]
    add_index :checklist_item_scheme_assignments, :display_order
  end
end
