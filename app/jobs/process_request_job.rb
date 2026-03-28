class ProcessRequestJob < ApplicationJob
  queue_as :default

  # Sidekiq-specific: 5 retries with exponential backoff (~5s, 25s, 125s, 625s, 3125s)
  sidekiq_options retry: 5, dead: false, backtrace: true

  sidekiq_retry_in do |count, _exception|
    (count ** 4) + 15 + (rand(30) * (count + 1))
  end

  sidekiq_retries_exhausted do |msg, _ex|
    id = msg['args'].first
    ClientRequest.where(id: id).update_all(
      status:        'failed',
      error_message: "Retries exhausted after #{msg['retry_count']} attempts: #{msg['error_message']}",
      updated_at:    Time.current
    )
    Rails.logger.error("[Job] retries exhausted request_id=#{id} error=#{msg['error_message']}")
  end

  def perform(request_id)
    log_info "starting request_id=#{request_id}"

    request = ClientRequest.find_by(id: request_id)
    return log_warn("request_id=#{request_id} not found, skipping") unless request

    # 1. Already in a terminal state — safe to skip (idempotent re-run guard)
    if request.terminal?
      return log_info("request_id=#{request_id} already #{request.status}, skipping")
    end

    # 2. Atomic acquisition: only move forward if status is still 'pending'
    #    This is a single SQL UPDATE ... WHERE status='pending' — prevents
    #    two concurrent workers from both processing the same job.
    rows_updated = ClientRequest
      .where(id: request_id, status: 'pending')
      .update_all(status: 'processing', updated_at: Time.current)

    if rows_updated == 0
      return log_warn("request_id=#{request_id} already acquired by another worker, skipping")
    end

    request.reload

    # 3. Check cancellation AFTER acquiring — prevents the TOCTOU race where
    #    a cancel comes in between the find_by and the update_all above.
    if request.cancelled?
      ClientRequest.where(id: request_id).update_all(status: 'cancelled', updated_at: Time.current)
      return log_info("request_id=#{request_id} was cancelled, releasing")
    end

    # 4. Delegate to service object
    service = ProcessRequestService.new(request)
    service.call

    log_info "completed request_id=#{request_id}"

  rescue ProcessRequestService::NonRetryableError => e
    # Business rule violation — do NOT retry, mark failed immediately
    log_error "non-retryable error request_id=#{request_id} error=#{e.message}"
    request&.update_columns(status: 'failed', error_message: e.message, updated_at: Time.current)
    # Do NOT re-raise — Sidekiq will not retry

  rescue ProcessRequestService::DownstreamError, Timeout::Error => e
    # Transient downstream failure — reset to pending so the atomic check
    # above passes on the next Sidekiq retry attempt
    log_error "retryable error request_id=#{request_id} error=#{e.message} retry=#{executions}"
    request&.update_columns(
      status:        'pending',
      error_message: "Attempt #{executions}: #{e.message}",
      retry_count:   (request&.retry_count || 0) + 1,
      updated_at:    Time.current
    )
    raise # re-raise so Sidekiq schedules the next retry

  rescue ActiveRecord::StaleObjectError => e
    # Optimistic lock conflict — another process updated this record concurrently
    log_warn "stale object conflict request_id=#{request_id}, will retry"
    raise # let Sidekiq retry

  rescue => e
    # Unexpected error — fail safe, do not retry unknown conditions
    log_error "unexpected error request_id=#{request_id} class=#{e.class} error=#{e.message}"
    request&.update_columns(status: 'failed', error_message: "#{e.class}: #{e.message}", updated_at: Time.current)
  end

  private

  def log_info(msg)  = Rails.logger.info("[ProcessRequestJob] #{msg}")
  def log_warn(msg)  = Rails.logger.warn("[ProcessRequestJob] #{msg}")
  def log_error(msg) = Rails.logger.error("[ProcessRequestJob] #{msg}")
end
