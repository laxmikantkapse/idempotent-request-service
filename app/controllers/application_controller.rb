class ApplicationController < ActionController::API
  before_action :set_request_id

  private

  def set_request_id
    request_id = request.headers['X-Request-Id'] || SecureRandom.uuid
    response.set_header('X-Request-Id', request_id)
    Rails.logger.tagged(request_id) { } # seeds the tag for this thread
    Thread.current[:request_id] = request_id
  end
end
