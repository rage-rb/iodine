require 'iodine' unless defined?(::Iodine::VERSION)
begin
  require 'rage/cli'
rescue LoadError
end

module Iodine
  # Iodine's {Iodine::Rack} module provides a Rack compliant interface (connecting Iodine to Rack) for an HTTP and Websocket Server.
  module Rack

    # Runs a Rack app, as par the Rack handler requirements.
    def self.run(app, options = {})
      if !defined?(Rage::CLI) && ENV["RSPEC_TEST_ENV"]
        Iodine.listen(service: :http, handler: app, port: options[:Port], address: options[:Host])
        Iodine.start
      else
        Rage::CLI.new([], { port: options[:Port], binding: options[:Host], environment: options[:environment] }).server
      end

      true
    end

    # patches an assumption by Rack, issue #98 code donated by @Shelvak (Néstor Coppi)
    def self.shutdown
      Iodine.stop
    end

    IODINE_RACK_LOADED = true
  end
end

ENV['RACK_HANDLER'] ||= 'iodine'

begin
  ::Rack::Handler.register('iodine', 'Iodine::Rack') if defined?(::Rack::Handler)
  ::Rack::Handler.register('Iodine', 'Iodine::Rack') if defined?(::Rack::Handler)
rescue StandardError
end
