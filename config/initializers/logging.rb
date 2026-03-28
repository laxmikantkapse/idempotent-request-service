if Rails.env.production? || ENV['JSON_LOGS'] == 'true'
  logger = ActiveSupport::Logger.new($stdout)
  logger.formatter = proc do |severity, time, _progname, msg|
    JSON.generate(
      timestamp: time.utc.iso8601(3),
      level:     severity,
      pid:       Process.pid,
      message:   msg
    ) + "\n"
  end
  Rails.application.config.logger = ActiveSupport::TaggedLogging.new(logger)
end
