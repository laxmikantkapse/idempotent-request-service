class ClientRequest < ApplicationRecord
  STATUSES = %w[pending processing completed failed cancelled].freeze

  validates :idempotency_key, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }
  validates :request_type, presence: true

  scope :stale_processing, -> {
    where(status: 'processing')
      .where('updated_at < ?', 10.minutes.ago)
  }

  def pending?    = status == 'pending'
  def processing? = status == 'processing'
  def completed?  = status == 'completed'
  def failed?     = status == 'failed'
  def cancelled?  = status == 'cancelled'
  def terminal?   = completed? || failed? || cancelled?
end
