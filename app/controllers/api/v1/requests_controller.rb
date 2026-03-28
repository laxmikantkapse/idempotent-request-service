module Api
  module V1
    class RequestsController < ApplicationController
      before_action :validate_presence_of_idempotency_key, only: [:create]
      before_action :validate_presence_of_request_type,    only: [:create]

      # POST /api/v1/requests
      def create
        result = ClientRequestService.create(
          idempotency_key: idempotency_key,
          attrs:           request_params
        )

        render json: serialized(result), status: result.status
      end

      # GET /api/v1/requests/:id
      def show
        result = ClientRequestService.find(params[:id])

        render json: serialized(result), status: result.status
      end

      # DELETE /api/v1/requests/:id
      def destroy
        result = ClientRequestService.cancel(params[:id])

        render json: serialized(result), status: result.status
      end

      private

      def request_params
        params.require(:request).permit(:request_type, payload: {})
      rescue ActionController::ParameterMissing
        params.permit(:request_type, payload: {})
      end

      def idempotency_key
        request.headers["Idempotency-Key"].presence || params[:idempotency_key].presence
      end

      def validate_presence_of_idempotency_key
        return if idempotency_key.present?

        render json: { error: "Idempotency-Key is required" }, status: :bad_request
      end

      def validate_presence_of_request_type
        return if request_params[:request_type].present?

        render json: { error: "request_type is required" }, status: :bad_request
      end

      def serialized(result)
        return { error: result.error } unless result.record

        serialize(result.record)
      end

      def serialize(req)
        {
          id:              req.id,
          idempotency_key: req.idempotency_key,
          status:          req.status,
          request_type:    req.request_type,
          payload:         req.payload,
          result:          req.result,
          error_message:   req.error_message,
          retry_count:     req.retry_count,
          processed_at:    req.processed_at,
          created_at:      req.created_at
        }
      end
    end
  end
end
