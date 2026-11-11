# frozen_string_literal: true

module Tungo
  # The rate-limit headers of one response.
  #
  # @!attribute limit
  #   @return [Integer, nil] requests allowed in the current window (+x-ratelimit-limit+)
  # @!attribute remaining
  #   @return [Integer, nil] requests left in the current window (+x-ratelimit-remaining+)
  # @!attribute reset
  #   @return [Integer, nil] seconds until the next window (+x-ratelimit-reset+)
  RateLimit = Data.define(:limit, :remaining, :reset) do
    # @return [Tungo::RateLimit, nil] nil when the response carries none of the headers
    def self.from_headers(headers)
      values = %w[x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset].map do |name|
        text = headers[name].to_s.strip
        text.match?(/\A-?[0-9]+\z/) ? text.to_i : nil
      end
      values.all?(&:nil?) ? nil : new(*values)
    end
  end

  # Status and headers of the HTTP response behind a result. Every result exposes it:
  # {Tungo::Model#api_response}, {Tungo::Page#api_response}, {Tungo::Stream#api_response};
  # operations without a response body return it directly.
  #
  # @!attribute status
  #   @return [Integer] HTTP status
  # @!attribute headers
  #   @return [Hash{String=>String}] response headers with lower-case names
  APIResponse = Data.define(:status, :headers) do
    # @return [String, nil] the value of a header, looked up case-insensitively
    def [](name)
      headers[name.to_s.downcase]
    end

    # @return [String, nil] the request id to quote to support (+x-request-id+)
    def request_id
      headers["x-request-id"]
    end

    # @return [Tungo::RateLimit, nil] the rate-limit headers of this very response
    def rate_limit
      RateLimit.from_headers(headers)
    end

    # @return [Boolean] true when the API replayed a stored response for a repeated Idempotency-Key
    def idempotent_replayed?
      headers["idempotent-replayed"] == "true"
    end
  end
end
