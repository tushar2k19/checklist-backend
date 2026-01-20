class CreateEvaluations < ActiveRecord::Migration[7.1]
  def change
    create_table :evaluations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :uploaded_file, null: false, foreign_key: true
      t.references :scheme, null: false, foreign_key: true
      t.references :document_type, null: false, foreign_key: true
      
      t.datetime :evaluation_date
      t.string :openai_thread_id
      
      t.json :summary_stats
      t.string :status, default: 'pending'
      t.integer :processing_time
      t.text :error_message

      t.timestamps
    end
    
    add_index :evaluations, :evaluation_date
    add_index :evaluations, [:scheme_id, :document_type_id]
    add_index :evaluations, :status
  end
end
