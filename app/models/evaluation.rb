class Evaluation < ApplicationRecord
  belongs_to :user
  belongs_to :uploaded_file
  belongs_to :scheme
  belongs_to :document_type
  
  has_many :evaluation_checklist_items, dependent: :destroy
  has_many :checklist_items, through: :evaluation_checklist_items

  # Validations
  validates :user_id, presence: true
  validates :uploaded_file_id, presence: true
  validates :scheme_id, presence: true
  validates :document_type_id, presence: true

  # Enums
  enum status: { 
    pending: 'pending', 
    processing: 'processing', 
    completed: 'completed', 
    failed: 'failed' 
  }

  # Scopes
  scope :recent, ->(days = 7) { where('created_at >= ?', days.days.ago).order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :by_scheme, ->(scheme_id) { where(scheme_id: scheme_id) }
  scope :completed, -> { where(status: 'completed') }

  # Callbacks
  before_create :set_evaluation_date

  def mark_as_completed!(thread_id, processing_time_sec, results)
    ActiveRecord::Base.transaction do
      update!(
        status: 'completed',
        openai_thread_id: thread_id,
        processing_time: processing_time_sec,
        error_message: nil
      )
      
      calculate_summary_stats
    end
  end

  def mark_as_failed!(message)
    update!(
      status: 'failed',
      error_message: message
    )
  end

  def calculate_summary_stats
    items = evaluation_checklist_items
    stats = {
      compliant: items.where(status: 'Yes').count,
      non_compliant: items.where(status: 'No').count,
      partial: items.where(status: 'Partial').count,
      total: items.count
    }
    
    update(summary_stats: stats)
    stats
  end
  
  private
  
  def set_evaluation_date
    self.evaluation_date ||= Time.current
  end
end


