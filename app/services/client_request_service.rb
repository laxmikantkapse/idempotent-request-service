class ClientRequestService
  Result = Struct.new(:ok?, :status, :record, :error, keyword_init: true)

  def self.create(idempotency_key:, attrs:)
    existing = ClientRequest.find_by(idempotency_key: idempotency_key)
    return Result.new(ok?: false, status: :conflict, record: existing) if existing

    record = ClientRequest.create!(
      idempotency_key: idempotency_key,
      request_type:    attrs[:request_type],
      payload:         attrs[:payload] || {}
    )

    ProcessRequestJob.perform_later(record.id.to_s)

    Result.new(ok?: true, status: :accepted, record: record)

  rescue ActiveRecord::RecordNotUnique
    # Race condition: two requests slipped past find_by — DB unique index wins.
    existing = ClientRequest.find_by!(idempotency_key: idempotency_key)
    Rails.logger.warn("[ClientRequestService] concurrent duplicate key=#{idempotency_key}, id=#{existing.id}")
    Result.new(ok?: false, status: :conflict, record: existing)

  rescue ActiveRecord::RecordInvalid => e
    Result.new(ok?: false, status: :unprocessable_entity, error: e.message)

  rescue => e
    Rails.logger.error("[ClientRequestService] unexpected error: #{e.class} #{e.message}")
    Result.new(ok?: false, status: :internal_server_error, error: "Internal server error")
  end

  def self.find(id)
    record = ClientRequest.find(id)
    Result.new(ok?: true, status: :ok, record: record)
  rescue ActiveRecord::RecordNotFound
    Result.new(ok?: false, status: :not_found, error: "Not found")
  end

  def self.cancel(id)
    record = ClientRequest.find(id)

    if record.terminal?
      return Result.new(
        ok?:   false,
        status: :unprocessable_entity,
        error:  "Cannot cancel a #{record.status} request"
      )
    end

    record.update!(status: "cancelled", cancelled_at: Time.current)
    Result.new(ok?: true, status: :ok, record: record)

  rescue ActiveRecord::RecordNotFound
    Result.new(ok?: false, status: :not_found, error: "Not found")
  end
end
