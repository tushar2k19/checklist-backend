class CreateChecklistItems < ActiveRecord::Migration[7.1]
  def change
    create_table :checklist_items do |t|
      t.text :item_text, null: false

      t.timestamps
    end
    
    # Adding FULLTEXT index for item_text (MySQL syntax)
    # If using PostgreSQL, syntax would be different, assuming MySQL based on todo.md
    add_index :checklist_items, :item_text, type: :fulltext
  end
end
