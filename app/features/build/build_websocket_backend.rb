require "faye/websocket"
require_relative "../../shared/logging_module"
require_relative "../build_runner/web_socket_build_runner_change_listener"

Faye::WebSocket.load_adapter("thin")

module FastlaneCI
  # Responsible for the real-time streaming of the build output
  # to the user's browser
  # This is a Rack middleware, that is called before any of the Sinatra code is called
  # it allows us to have the real time web socket connection. Inside the `.call` method
  # we check if the current request is a socket connection or traditional HTTPs
  class BuildWebsocketBackend
    include FastlaneCI::Logging

    KEEPALIVE_TIME = 30 # in seconds

    def initialize(app)
      logger.debug("Setting up new BuildWebsocketBackend")
      @app = app
    end

    def call(env)
      unless Faye::WebSocket.websocket?(env)
        # This is a regular HTTP call (no socket connection)
        # so just redirect to the user's app
        return @app.call(env)
      end

      ws = Faye::WebSocket.new(env, nil, { ping: KEEPALIVE_TIME })

      ws.on(:open) do |event|
        logger.debug([:open, ws.object_id])

        request_params = Rack::Request.new(env).params
        build_number = request_params["build_number"].to_i
        project_id = request_params["project_id"]

        current_build_runner = Services.build_runner_service.find_build_runner(
          project_id: project_id,
          build_number: build_number
        )
        next if current_build_runner.nil? # this is the case if the build was run a while ago

        # subscribe the current socket to events from the remote_runner
        # as soon as a subscriber is returned, they will receive all historical items as well.
        @subscriber = current_build_runner.subscribe do |invocation_response|
          ws.send(invocation_response)
        end
        logger.debug("subscribed #{@subscriber} to the project topic.")
      end

      ws.on(:message) do |event|
        # We don't use this right now
        logger.debug([:message, event.data])
      end

      ws.on(:close) do |event|
        logger.debug([:close, ws.object_id, event.code, event.reason])

        request_params = Rack::Request.new(env).params
        build_number = request_params["build_number"].to_i
        project_id = request_params["project_id"]

        current_build_runner = Services.build_runner_service.find_build_runner(
          project_id: project_id,
          build_number: build_number
        )
        next if current_build_runner.nil? # this is the case if the build was run a while ago

        current_build_runner.unsubscribe(@subscriber)
      end

      # Return async Rack response
      return ws.rack_response
    end
  end
end
