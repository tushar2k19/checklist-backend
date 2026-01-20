class UploadedFile < ApplicationRecord
  belongs_to :user
  has_many :evaluations, dependent: :destroy

  # Validations
  validates :original_filename, presence: true
  validates :display_name, presence: true
  validates :file_size, presence: true, numericality: { greater_than: 0 }
  validates :mime_type, presence: true

  # Enums
  enum status: { 
    uploaded: 'uploaded', 
    processing: 'processing', 
    ready: 'ready', 
    error: 'error', 
    deleted: 'deleted' 
  }, _prefix: true

  enum vector_store_status: { 
    pending: 'pending', 
    processing: 'processing', 
    completed: 'completed', 
    failed: 'failed' 
  }, _prefix: :vector_store

  # Scopes
  scope :active, -> { where.not(status: 'deleted') }
  scope :expired, -> { where('expires_at < ?', Time.current) }
  scope :ready_for_analysis, -> { where(status: 'ready', vector_store_status: 'completed') }
  scope :recent, -> { order(created_at: :desc) }

  # Callbacks
  before_create :set_expires_at

  def file_size_mb
    (file_size.to_f / 1.megabyte).round(2)
  end

  def file_size_kb
    (file_size.to_f / 1.kilobyte).round(2)
  end

  def expired?
    expires_at.present? && expires_at < Time.current
  end

  def ready_for_analysis?
    status_ready? && vector_store_completed?
  end

  def mark_as_ready!
    update!(status: 'ready', error_message: nil)
  end

  def mark_as_deleted!
    update!(status: 'deleted', deleted_at: Time.current)
  end

  def mark_as_error!(message)
    update!(status: 'error', error_message: message)
  end
  
  def vector_store_ready?
    vector_store_completed?
  end

  # Progress stage helpers
  def update_progress_stage!(stage)
    update!(progress_stage: stage)
  end

  def progress_stage_display
    case progress_stage
    when 'validating'
      'Validating file...'
    when 'uploading_file'
      'Uploading file to OpenAI...'
    when 'creating_vector_store'
      'Creating vector store...'
    when 'adding_file_to_vector_store'
      'Adding file to vector store...'
    when 'generating_embeddings'
      'Generating embeddings...'
    when 'completed'
      'Ready for analysis'
    when 'error'
      "Error: #{error_message}"
    else
      'Processing...'
    end
  end

  private

  def set_expires_at
    self.expires_at ||= 30.days.from_now
  end
end


