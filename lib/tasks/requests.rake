namespace :requests do
  desc "Reset stale 'processing' requests back to 'pending' and re-enqueue them"
  task recover_stale: :environment do
    stale_threshold = ENV.fetch('STALE_MINUTES', '15').to_i.minutes.ago

    stale = ClientRequest.where(status: 'processing')
                         .where('updated_at < ?', stale_threshold)

    count = stale.count
    Rails.logger.info("[Rake] found #{count} stale requests to recover")

    stale.find_each do |req|
      Rails.logger.warn("[Rake] recovering stale request_id=#{req.id} stuck since #{req.updated_at}")
      req.update_columns(status: 'pending', updated_at: Time.current)
      ProcessRequestJob.perform_later(req.id.to_s)
    end

    puts "Recovered #{count} stale requests."
  end
end
