# frozen_string_literal: true

require "action_cable"
require "action_cable/subscription_adapter/base"
require "action_cable/subscription_adapter/channel_prefix"
require "securerandom"
require "erb"
require_relative "../../laravel_cloud/websockets"

module ActionCable
  module SubscriptionAdapter
    # `adapter: cloud` in config/cable.yml. Browsers hold their socket to Cloud
    # WebSockets; channel commands reach Rails over same-origin HTTP
    # (Middleware) and run against a virtual Action Cable connection
    # (Session), whose frames go back through Cloud WebSockets.
    #
    # Broadcasting only publishes over HTTP, so processes that never subscribe
    # (jobs, consoles) don't open a connection.
    class Cloud < Base
      prepend ChannelPrefix

      Websockets = ::LaravelCloud::Websockets

      # A malformed command from the browser transport.
      class InvalidCommand < Websockets::Error; end

      def self.stream_channel(stream)
        "private-roc-stream-#{Digest::SHA256.hexdigest(stream)}"
      end

      # The owner cookie binds connection tokens to the browser that opened them.
      def self.owner(request)
        value = Rack::Utils.parse_cookies_header(request.get_header("HTTP_COOKIE").to_s)["__laravel_cloud_owner"]
        return unless value.is_a?(String) && value.ascii_only? && value.match?(/\A[0-9a-f]{48}\.[0-9a-f]{64}\z/)
        nonce, signature = value.split(".")
        nonce if ActiveSupport::SecurityUtils.secure_compare(Websockets.sign("roc-owner:#{nonce}"), signature)
      end

      def self.owner_cookie
        nonce = SecureRandom.hex(24)
        "#{nonce}.#{Websockets.sign("roc-owner:#{nonce}")}"
      end

      def self.runtime
        @runtime_lock ||= Mutex.new
        @runtime_lock.synchronize do
          if !@runtime || @runtime.pid != Process.pid || !@runtime.alive?
            @runtime = Runtime.new
          end
          @runtime
        end
      end

      def initialize(server)
        Websockets.settings
        super
        @bindings = {}
        @bindings_lock = Mutex.new
      end

      def broadcast(channel, payload)
        Websockets.publish(self.class.stream_channel(channel), "cloud-broadcast", payload)
      end

      def subscribe(channel, callback, success_callback = nil)
        runtime = self.class.runtime
        @bindings_lock.synchronize { @bindings[[channel, callback]] = runtime }
        runtime.subscribe(channel, callback, success_callback)
      end

      def unsubscribe(channel, callback)
        runtime = @bindings_lock.synchronize { @bindings.delete([channel, callback]) }
        runtime&.unsubscribe(channel, callback)
      end

      def shutdown
        runtimes = @bindings_lock.synchronize { @bindings.values.uniq }
        runtimes.each(&:stop)
      end
    end
  end
end

require_relative "cloud/runtime"
require_relative "cloud/middleware"
require_relative "cloud/railtie" if defined?(Rails::Railtie)
