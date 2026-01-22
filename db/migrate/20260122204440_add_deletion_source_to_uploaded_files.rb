class AddDeletionSourceToUploadedFiles < ActiveRecord::Migration[7.1]
  def change
    add_column :uploaded_files, :deletion_source, :string
  end
end
