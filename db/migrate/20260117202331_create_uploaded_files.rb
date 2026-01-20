class CreateUploadedFiles < ActiveRecord::Migration[7.1]
  def change
    create_table :uploaded_files do |t|
      t.references :user, null: false, foreign_key: true
      t.string :original_filename, null: false
      t.string :display_name, null: false
      t.bigint :file_size, null: false
      t.string :mime_type, default: 'application/pdf'
      
      # OpenAI Integration
      t.string :openai_file_id
      t.string :openai_vector_store_id
      t.string :vector_store_status, default: 'pending'
      
      # File Deduplication
      t.string :sha256_hash
      
      # Lifecycle Management
      t.datetime :uploaded_at
      t.datetime :last_analyzed_at
      t.datetime :expires_at
      t.datetime :deleted_at
      
      # Status
      t.string :status, default: 'uploaded'
      t.text :error_message

      t.timestamps
    end
    
    add_index :uploaded_files, :openai_file_id, unique: true
    add_index :uploaded_files, :openai_vector_store_id, unique: true
    add_index :uploaded_files, :status
    add_index :uploaded_files, :expires_at
    add_index :uploaded_files, :sha256_hash
  end
end
