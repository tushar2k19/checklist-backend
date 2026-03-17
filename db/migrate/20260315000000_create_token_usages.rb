# frozen_string_literal: true

class CreateTokenUsages < ActiveRecord::Migration[7.1]
  def change
    create_table :token_usages, charset: 'utf8mb4', collation: 'utf8mb4_0900_ai_ci' do |t|
      # source: evaluation | followup (determines Evaluation input/output vs Follow-up input/output)
      t.string :source, null: false, limit: 20
      t.bigint :input_tokens, null: false, default: 0
      t.bigint :output_tokens, null: false, default: 0
      t.bigint :total_tokens, null: false, default: 0
      t.references :user, null: true, foreign_key: true
      t.references :evaluation, null: true, foreign_key: true

      t.timestamps
    end

    add_index :token_usages, [:source, :created_at]
    add_index :token_usages, :created_at
  end
end
