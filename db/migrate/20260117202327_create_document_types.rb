class CreateDocumentTypes < ActiveRecord::Migration[7.1]
  def change
    create_table :document_types do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_index :document_types, :name, unique: true
  end
end
