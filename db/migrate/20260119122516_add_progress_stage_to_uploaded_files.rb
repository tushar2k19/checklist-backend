class AddProgressStageToUploadedFiles < ActiveRecord::Migration[7.1]
  def change
    add_column :uploaded_files, :progress_stage, :string
    add_index :uploaded_files, :progress_stage
  end
end
