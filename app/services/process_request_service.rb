class ProcessRequestService
  class DownstreamError < StandardError; end
  class NonRetryableError < StandardError; end

  RETRYABLE_ERRORS   = [DownstreamError, Timeout::Error, Errno::ECONNREFUSED].freeze
  NON_RETRYABLE_ERRORS = [NonRetryableError, ArgumentError].freeze

  def initialize(request)
    @request = request
    @logger  = Rails.logger
  end

  def call
    validate_payload!
    result = call_downstream
    @request.update!(
      status:       'completed',
      result:       result,
      processed_at: Time.current
    )
    result
  end

  def retryable_error?(error)
    RETRYABLE_ERRORS.any? { |klass| error.is_a?(klass) }
  end

  private

  def validate_payload!
    # Add your real payload schema validation here
    raise NonRetryableError, "Missing amount" if @request.request_type == 'payment' &&
                                                  @request.payload['amount'].blank?
  end

  def call_downstream
    # Simulates real HTTP call with timeout
    @logger.info("[Service] calling downstream for request=#{@request.id} type=#{@request.request_type}")

    simulate_latency
    simulate_failure

    {
      processed:   true,
      external_id: SecureRandom.uuid,
      timestamp:   Time.current.iso8601,
      type:        @request.request_type
    }
  end

  def simulate_latency
    sleep(rand(0.5..2.0))
  end

  def simulate_failure
    roll = rand
    raise DownstreamError,    "Downstream timeout (simulated)"      if roll < 0.15
    raise NonRetryableError,  "Invalid business rule (simulated)"   if roll < 0.17
    # 83%+ succeed normally
  end
end
