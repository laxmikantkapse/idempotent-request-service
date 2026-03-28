require 'rails_helper'

RSpec.describe 'Api::V1::Requests', type: :request do
  let(:headers) { { 'Content-Type' => 'application/json', 'Idempotency-Key' => 'key-abc-123' } }
  let(:valid_params) { { request_type: 'payment', payload: { amount: 100 } }.to_json }

  describe 'POST /api/v1/requests' do
    context 'with valid params and unique key' do
      it 'returns 202 and enqueues a job' do
        expect {
          post '/api/v1/requests', params: valid_params, headers: headers
        }.to have_enqueued_job(ProcessRequestJob)

        expect(response).to have_http_status(:accepted)
        expect(JSON.parse(response.body)['status']).to eq('pending')
      end
    end

    context 'with missing Idempotency-Key' do
      it 'returns 400' do
        post '/api/v1/requests', params: valid_params,
             headers: { 'Content-Type' => 'application/json' }
        expect(response).to have_http_status(:bad_request)
      end
    end

    context 'with a duplicate key' do
      before { create(:client_request, idempotency_key: 'key-abc-123') }

      it 'returns 409' do
        post '/api/v1/requests', params: valid_params, headers: headers
        expect(response).to have_http_status(:conflict)
      end
    end

    context 'with missing request_type' do
      it 'returns 400' do
        post '/api/v1/requests',
             params: { payload: {} }.to_json,
             headers: headers
        expect(response).to have_http_status(:bad_request)
      end
    end
  end

  describe 'GET /api/v1/requests/:id' do
    let!(:cr) { create(:client_request) }

    it 'returns 200 with the request' do
      get "/api/v1/requests/#{cr.id}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)['id']).to eq(cr.id)
    end

    it 'returns 404 for unknown id' do
      get '/api/v1/requests/00000000-0000-0000-0000-000000000000'
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'DELETE /api/v1/requests/:id' do
    let!(:cr) { create(:client_request, status: 'pending') }

    it 'cancels a pending request' do
      delete "/api/v1/requests/#{cr.id}"
      expect(response).to have_http_status(:ok)
      expect(cr.reload.status).to eq('cancelled')
    end

    it 'cannot cancel a completed request' do
      cr.update!(status: 'completed')
      delete "/api/v1/requests/#{cr.id}"
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
