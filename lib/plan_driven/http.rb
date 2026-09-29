# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module PlanDriven
  # A small JSON client over net/http. The transport is swappable so the specs never touch the
  # network: anything responding to `call(method, url, headers, body)` and returning
  # `[status, body_string]` works.
  class HTTP
    Response = Struct.new(:status, :body, keyword_init: true) do
      def success?
        status.between?(200, 299)
      end

      def json
        body.to_s.strip.empty? ? {} : JSON.parse(body)
      rescue JSON::ParserError
        {}
      end
    end

    class << self
      attr_writer :transport

      def transport
        @transport ||= method(:net_http)
      end

      def reset!
        @transport = nil
      end

      def request(method, url, headers: {}, body: nil, timeout: 60)
        payload = body.nil? || body.is_a?(String) ? body : JSON.generate(body)
        status, text = transport.call(method.to_s.upcase, url, headers, payload, timeout)
        Response.new(status: status.to_i, body: text.to_s)
      rescue Net::OpenTimeout, Net::ReadTimeout
        raise ProviderError, "#{URI(url).host} did not respond within #{timeout}s"
      rescue SocketError, SystemCallError => e
        raise ProviderError, "Could not reach #{URI(url).host}: #{e.message}"
      end

      private

      def net_http(method, url, headers, body, timeout)
        uri = URI(url)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = 10
        http.read_timeout = timeout
        request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri, headers)
        request.body = body if body
        response = http.request(request)
        [response.code.to_i, response.body]
      end
    end
  end
end
