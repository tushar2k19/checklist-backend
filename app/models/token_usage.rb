# frozen_string_literal: true

class TokenUsage < ApplicationRecord
  SOURCE_EVALUATION = 'evaluation'
  SOURCE_FOLLOWUP = 'followup'

  belongs_to :user, optional: true
  belongs_to :evaluation, optional: true

  validates :source, presence: true, inclusion: { in: [SOURCE_EVALUATION, SOURCE_FOLLOWUP] }
  validates :input_tokens, :output_tokens, :total_tokens, numericality: { greater_than_or_equal_to: 0 }

  scope :evaluation, -> { where(source: SOURCE_EVALUATION) }
  scope :followup, -> { where(source: SOURCE_FOLLOWUP) }
  scope :since, ->(time) { where('created_at >= ?', time) }

  # Record token usage for an evaluation run (all batches summed by caller).
  def self.record_evaluation!(user_id:, evaluation_id:, input_tokens:, output_tokens:, total_tokens: nil)
    total_tokens ||= (input_tokens.to_i + output_tokens.to_i)
    create!(
      source: SOURCE_EVALUATION,
      user_id: user_id,
      evaluation_id: evaluation_id,
      input_tokens: input_tokens.to_i,
      output_tokens: output_tokens.to_i,
      total_tokens: total_tokens
    )
  end

  # Record token usage for a single follow-up question/answer.
  def self.record_followup!(user_id:, evaluation_id:, input_tokens:, output_tokens:, total_tokens: nil)
    total_tokens ||= (input_tokens.to_i + output_tokens.to_i)
    create!(
      source: SOURCE_FOLLOWUP,
      user_id: user_id,
      evaluation_id: evaluation_id,
      input_tokens: input_tokens.to_i,
      output_tokens: output_tokens.to_i,
      total_tokens: total_tokens
    )
  end

  # Aggregated analytics: Evaluation input, Evaluation output, Follow-up input, Follow-up output, total.
  # Optional scope: since (Time) for date range.
  def self.analytics(since_time: nil)
    rel = all
    rel = rel.since(since_time) if since_time.present?

    eval_usage = rel.evaluation.sum(:input_tokens) + rel.evaluation.sum(:output_tokens)
    followup_usage = rel.followup.sum(:input_tokens) + rel.followup.sum(:output_tokens)

    {
      evaluation_input: rel.evaluation.sum(:input_tokens),
      evaluation_output: rel.evaluation.sum(:output_tokens),
      followup_input: rel.followup.sum(:input_tokens),
      followup_output: rel.followup.sum(:output_tokens),
      total_tokens: rel.sum(:total_tokens),
      total_evaluation_tokens: rel.evaluation.sum(:total_tokens),
      total_followup_tokens: rel.followup.sum(:total_tokens),
      evaluations_count: rel.evaluation.distinct.count(:evaluation_id),
      followup_events_count: rel.followup.count
    }
  end
end
