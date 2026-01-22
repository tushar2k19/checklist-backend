class AddSoftDeleteToEvaluations < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluations, :deleted_at, :datetime
    add_reference :evaluations, :deleted_by, foreign_key: { to_table: :users }, null: true
    
    add_index :evaluations, :deleted_at
  end
end
