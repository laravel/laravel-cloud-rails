# frozen_string_literal: true

require "net/http"
require "openssl"
require "digest"
require "json"
require "monitor"
require "socket"
require "concurrent"
require "websocket/driver"

module LaravelCloud
  # Laravel Cloud managed WebSockets: a Pusher-compatible (Reverb) server whose
  # connection settings Cloud injects as PUSHER_* variables.
  module Websockets
    class Error < LaravelCloud::Error; end

    # The PUSHER_* variables are missing.
    class NotConfigured < Error; end

    # The server can't be reached, or refused the request or connection.
    class Unavailable < Error; end

    # An event too large for the server to accept.
    class PayloadTooLarge < Error; end

    VARIABLES = %w[PUSHER_APP_ID PUSHER_APP_KEY PUSHER_APP_SECRET PUSHER_HOST PUSHER_PORT PUSHER_SCHEME].freeze

    def self.enabled?
      VARIABLES.all? { |key| ENV[key] && !ENV[key].empty? }
    end

    def self.settings
      raise NotConfigured, "Laravel Cloud WebSockets need #{VARIABLES.join(', ')}" unless enabled?
      scheme = ENV.fetch("PUSHER_SCHEME")
      raise Error, "PUSHER_SCHEME must be http or https" unless %w[http https].include?(scheme)
      port = Integer(ENV.fetch("PUSHER_PORT"))
      raise Error, "Invalid PUSHER_PORT" unless (1..65535).cover?(port)
      { host: ENV.fetch("PUSHER_HOST"), port: port, scheme: scheme, key: ENV.fetch("PUSHER_APP_KEY") }
    end

    # Signs a socket's subscription to a private channel.
    def self.authorize(socket_id, channel)
      "#{ENV.fetch('PUSHER_APP_KEY')}:#{sign("#{socket_id}:#{channel}")}"
    end

    def self.sign(value)
      OpenSSL::HMAC.hexdigest("SHA256", ENV.fetch("PUSHER_APP_SECRET"), value)
    end

    # Triggers an event through the server's HTTP API.
    def self.publish(channel, event, data)
      body = JSON.generate(name: event, channels: [channel], data: JSON.generate(data))
      # Reverb refuses HTTP requests over 10 KB (max_request_size), headers
      # included; the auth query and headers take roughly 350 bytes.
      raise PayloadTooLarge, "Message exceeds the backend payload limit" if body.bytesize > 9500
      path = "/apps/#{ENV.fetch('PUSHER_APP_ID')}/events"
      parameters = { "auth_key" => ENV.fetch("PUSHER_APP_KEY"), "auth_timestamp" => Time.now.to_i.to_s, "auth_version" => "1.0", "body_md5" => Digest::MD5.hexdigest(body) }
      query = URI.encode_www_form(parameters.sort)
      config = settings
      klass = config[:scheme] == "https" ? URI::HTTPS : URI::HTTP
      uri = klass.build(host: config[:host], port: config[:port], path: path, query: "#{query}&auth_signature=#{sign("POST\n#{path}\n#{query}")}")
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 3) do |http|
        http.post(uri.request_uri, body, { "Content-Type" => "application/json" })
      end
      raise Unavailable, "WebSocket backend returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      true
    rescue IOError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => error
      raise Unavailable, "WebSocket backend unavailable (#{error.class})"
    end
  end
end

require_relative "websockets/client"
