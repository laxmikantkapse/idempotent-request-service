FactoryBot.define do
  factory :client_request do
    idempotency_key { SecureRandom.uuid }
    request_type    { 'payment' }
    status          { 'pending' }
    payload         { { amount: 100, currency: 'USD' } }
  end
end
