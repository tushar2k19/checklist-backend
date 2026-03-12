class AddOpenaiFollowupThreadIdToEvaluationChecklistItems < ActiveRecord::Migration[7.1]
  def change
    add_column :evaluation_checklist_items, :openai_followup_thread_id, :string
    add_index :evaluation_checklist_items, :openai_followup_thread_id
  end
end
