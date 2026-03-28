module Api
  module V1
    class RequestsController < ApplicationController
      before_action :validate_params, only: [:create]

      # POST /api/v1/requests
			def create
				idempotency_key = request.headers['Idempotency-Key'].presence || params[:idempotency_key].presence

				return render json: { error: 'Idempotency-Key is required' }, status: :bad_request unless idempotency_key
				return render json: { error: 'request_type is required' }, status: :bad_request unless params[:request_type].present?

				existing = ClientRequest.find_by(idempotency_key: idempotency_key)
				return render json: serialize(existing), status: :conflict if existing

				client_request = ClientRequest.create!(
					idempotency_key: idempotency_key,
					request_type:    params[:request_type],
					payload:         params[:payload]&.to_unsafe_h || {}
				)

				ProcessRequestJob.perform_later(client_request.id.to_s)
				render json: serialize(client_request), status: :accepted

			rescue ActiveRecord::RecordNotUnique
				# Two concurrent requests both passed the find_by check — DB unique index wins
				existing = ClientRequest.find_by!(idempotency_key: idempotency_key)
				Rails.logger.warn("[API] concurrent duplicate key=#{idempotency_key}, returning existing #{existing.id}")
				render json: serialize(existing), status: :conflict

			rescue ActiveRecord::RecordInvalid => e
				render json: { error: e.message }, status: :unprocessable_entity

			rescue => e
				Rails.logger.error("[API] unexpected error: #{e.class} #{e.message}")
				render json: { error: 'Internal server error' }, status: :internal_server_error
			end

      # GET /api/v1/requests/:id
      def show
        client_request = ClientRequest.find(params[:id])
        render json: serialize(client_request), status: :ok
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      # DELETE /api/v1/requests/:id  (cancellation)
      def destroy
        client_request = ClientRequest.find(params[:id])

        if client_request.terminal?
          return render json: { error: "Cannot cancel a #{client_request.status} request" },
                        status: :unprocessable_entity
        end

        client_request.update!(status: 'cancelled', cancelled_at: Time.current)
        render json: serialize(client_request), status: :ok

      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Not found' }, status: :not_found
      end

      private

      def validate_params
        unless params[:request_type].present?
          render json: { error: 'request_type is required' }, status: :bad_request
        end
      end

      def serialize(req)
        {
          id: req.id,
          idempotency_key: req.idempotency_key,
          status: req.status,
          request_type: req.request_type,
          payload: req.payload,
          result: req.result,
          error_message: req.error_message,
          retry_count: req.retry_count,
          processed_at: req.processed_at,
          created_at: req.created_at
        }
      end
    end
  end
end
