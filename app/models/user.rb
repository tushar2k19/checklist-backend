class User < ApplicationRecord
  has_secure_password

  # Associations
  has_many :uploaded_files, dependent: :destroy
  has_many :evaluations, dependent: :destroy

  # Validations
  validates :email, presence: true, uniqueness: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password, length: { minimum: 6 }, allow_nil: true
  validates :first_name, presence: true
  validates :last_name, presence: true
  
  # Enums
  enum role: { user: 0, admin: 1 }

  # Callbacks
  before_save { self.email = email.downcase }

  # Instance methods
  def full_name
    "#{first_name} #{last_name}".strip
  end

  def display_name
    full_name.presence || email.split('@').first.humanize
  end

  def admin?
    role == 'admin'
  end

  def user?
    role == 'user'
  end

  # Class methods
  def self.find_by_email(email)
    find_by(email: email&.downcase)
  end

  # Statistics methods
  def file_count
    uploaded_files.active.count
  end

  def evaluation_count
    evaluations.count
  end

  def last_activity_at
    evaluations.maximum(:created_at) || uploaded_files.maximum(:created_at) || created_at
  end
end
