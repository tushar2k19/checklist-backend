class CreateSchemes < ActiveRecord::Migration[7.1]
  def change
    create_table :schemes do |t|
      t.string :name, null: false

      t.timestamps
    end
    add_index :schemes, :name, unique: true
  end
end
