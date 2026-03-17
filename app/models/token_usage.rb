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

  # Per-evaluation breakdown for "per document costs" UI.
  # Returns an array of hashes keyed by evaluation_id with both evaluation and follow-up token usage.
  def self.per_evaluation_breakdown(since_time: nil)
    rel = where.not(evaluation_id: nil)
    rel = rel.since(since_time) if since_time.present?

    usage_by_eval_and_source = rel
      .group(:evaluation_id, :source)
      .pluck(
        :evaluation_id,
        :source,
        Arel.sql('COALESCE(SUM(input_tokens), 0)'),
        Arel.sql('COALESCE(SUM(output_tokens), 0)'),
        Arel.sql('COALESCE(SUM(total_tokens), 0)')
      )

    eval_ids = usage_by_eval_and_source.map { |row| row[0] }.uniq
    evaluations_by_id = Evaluation
      .includes(:uploaded_file, :scheme, :document_type)
      .where(id: eval_ids)
      .index_by(&:id)

    acc = Hash.new do |h, eval_id|
      h[eval_id] = {
        evaluation_id: eval_id,
        evaluation_input: 0,
        evaluation_output: 0,
        evaluation_total: 0,
        followup_input: 0,
        followup_output: 0,
        followup_total: 0
      }
    end

    usage_by_eval_and_source.each do |evaluation_id, source, input_sum, output_sum, total_sum|
      row = acc[evaluation_id]
      if source == SOURCE_EVALUATION
        row[:evaluation_input] = input_sum.to_i
        row[:evaluation_output] = output_sum.to_i
        row[:evaluation_total] = total_sum.to_i
      elsif source == SOURCE_FOLLOWUP
        row[:followup_input] = input_sum.to_i
        row[:followup_output] = output_sum.to_i
        row[:followup_total] = total_sum.to_i
      end
    end

    acc.values.map do |row|
      ev = evaluations_by_id[row[:evaluation_id]]
      row.merge(
        evaluation_created_at: ev&.created_at&.iso8601,
        evaluation_status: ev&.status,
        scheme_name: ev&.scheme&.name,
        document_type_name: ev&.document_type&.name,
        file_name: ev&.uploaded_file&.display_name || ev&.uploaded_file&.original_filename,
        total_tokens: row[:evaluation_total].to_i + row[:followup_total].to_i
      )
    end.sort_by { |r| r[:evaluation_created_at].to_s }.reverse
  end
end
