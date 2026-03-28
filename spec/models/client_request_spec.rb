require 'rails_helper'

RSpec.describe ClientRequest, type: :model do
  subject(:request) { build(:client_request) }

  it { is_expected.to validate_presence_of(:idempotency_key) }
  it { is_expected.to validate_presence_of(:request_type) }
  it { is_expected.to validate_uniqueness_of(:idempotency_key) }

  describe 'status predicates' do
    %w[pending processing completed failed cancelled].each do |status|
      it "recognises #{status}?" do
        request.status = status
        expect(request.public_send("#{status}?")).to be true
      end
    end
  end

  describe '#terminal?' do
    it 'is true for completed, failed, cancelled' do
      %w[completed failed cancelled].each do |s|
        request.status = s
        expect(request.terminal?).to be true
      end
    end

    it 'is false for pending and processing' do
      %w[pending processing].each do |s|
        request.status = s
        expect(request.terminal?).to be false
      end
    end
  end
end
