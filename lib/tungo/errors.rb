# frozen_string_literal: true

module Tungo
  # Base class of every error raised by the SDK.
  class Error < StandardError; end

  # The client is misconfigured, for example an authenticated call without an API key.
  # Raised locally, before any request is made.
  class ConfigError < Error; end

  # An argument was rejected locally, before any request was made.
  class ValidationError < Error; end

  # A money amount could not be converted exactly (malformed, not finite or outside int64).
  class MoneyError < ValidationError; end

  # The request never produced a response: DNS failure, refused or dropped connection, TLS failure.
  # The original exception is available through +#cause+.
  class ConnectionError < Error; end

  # The request did not finish within its timeout. The original exception, when there is one,
  # is available through +#cause+.
  class TimeoutError < Error; end

  # A polling helper (+wait_for_run+, +wait_for_batch+, +run_scenario_and_wait+) reached its
  # deadline. This is a local condition, not an HTTP 408.
  class WaitTimeoutError < TimeoutError; end

  # A successful (2xx) response whose body could not be decoded: not JSON, truncated, empty, or
  # of an unexpected shape. Never retried.
  class DecodeError < Error
    # @return [Tungo::APIResponse, nil] status and headers of the response
    attr_reader :api_response
    # @return [String, nil] the raw body as received
    attr_reader :body

    def initialize(message, api_response: nil, body: nil)
      super(message)
      @api_response = api_response
      @body = body
    end
  end

  # Auto-pagination was stopped because the API returned the same cursor twice.
  class PaginationError < Error; end

  # A server-sent event stream reported a failure that is not part of the typed event union
  # (for example the feed stream's +error+ event).
  class StreamError < Error
    # @return [String, nil] machine-readable code sent by the server
    attr_reader :code
    # @return [Object] the decoded event data
    attr_reader :data

    def initialize(message, code: nil, data: nil)
      super(message)
      @code = code
      @data = data
    end
  end

  # A webhook could not be verified. +reason+ is one of +:invalid_tolerance+, +:invalid_secret+,
  # +:missing_header+, +:malformed_timestamp+, +:timestamp_too_old+, +:timestamp_too_new+,
  # +:signature_mismatch+, +:invalid_payload+.
  class WebhookVerificationError < Error
    # @return [Symbol]
    attr_reader :reason

    def initialize(message, reason:)
      super(message)
      @reason = reason
    end
  end

  # The API answered with an error status. The subclass is chosen by the +error.type+ field of
  # the response body and falls back to the HTTP status when the body is not the API's error
  # envelope.
  class APIError < Error
    # Statuses that are worth repeating when the request is safe to repeat.
    RETRYABLE_STATUSES = [408, 429, 500, 502, 503, 504].freeze

    # @return [Integer, nil] HTTP status; nil for an error delivered as a stream event
    attr_reader :status
    # @return [String] +error.type+ as sent by the API (even when unknown), or the status fallback
    attr_reader :type
    # @return [String, nil] +error.code+
    attr_reader :code
    # @return [String, nil] +error.message+ exactly as sent by the API
    attr_reader :api_message
    # @return [String, nil] request id from the body, else from the +x-request-id+ header
    attr_reader :request_id
    # @return [Array<Tungo::Models::FieldError>] per-field validation errors, empty when absent
    attr_reader :fields
    # @return [Float, nil] seconds the server asked to wait (+retry-after-ms+ / +Retry-After+)
    attr_reader :retry_after
    # @return [Hash{String=>String}] response headers with lower-case names
    attr_reader :headers
    # @return [String, nil] the raw response body
    attr_reader :body
    # @return [Hash{String=>Object}] every other property of +error+ (+resets_at+, +permission+, ...)
    attr_reader :extra

    def initialize(type:, status: nil, api_message: nil, code: nil, request_id: nil, fields: [],
                   retry_after: nil, headers: {}, body: nil, extra: {}, envelope: true)
      @status = status
      @type = type
      @api_message = api_message
      @code = code
      @request_id = request_id
      @fields = fields.freeze
      @retry_after = retry_after
      @headers = headers.freeze
      @body = body
      @extra = extra.freeze
      @envelope = envelope
      super(describe)
    end

    # @return [Boolean] true when the body was the API's error envelope
    def envelope?
      @envelope
    end

    # @return [Tungo::RateLimit, nil] rate-limit headers of this very response
    def rate_limit
      RateLimit.from_headers(@headers)
    end

    # Builds the typed error for an HTTP error response.
    #
    # @param status [Integer]
    # @param headers [Hash] response headers (any case)
    # @param body [String, nil] raw response body
    # @param now [Time] clock used for an HTTP-date +Retry-After+
    # @return [Tungo::APIError]
    def self.from_response(status:, headers:, body:, now: Time.now)
      headers = Internal::Util.normalize_headers(headers)
      body = Internal::Util.text(body)
      fallback = status_fallback(status)
      attrs = {
        status: status, type: fallback, headers: headers, body: body, envelope: false,
        retry_after: Internal::Util.parse_retry_after(headers, now: now),
        request_id: presence(headers["x-request-id"])
      }
      detail, request_id = envelope_of(body)
      return ERROR_CLASSES.fetch(fallback).new(**attrs) if detail.nil?

      attrs[:request_id] = request_id if request_id
      from_detail(detail, fallback, attrs)
    end

    # Builds the typed error for an +error+ event of a chat stream.
    #
    # @param event [Hash, Tungo::Model] the event data: +{type: "error", error: {...}, request_id}+
    # @return [Tungo::APIError]
    def self.from_event(event, headers: {})
      data = event.respond_to?(:to_wire) ? event.to_wire : event
      detail = data.is_a?(Hash) ? data["error"] : nil
      detail = {} unless detail.is_a?(Hash)
      detail = { "type" => "api_error", "message" => "The stream reported an error" }.merge(detail)
      attrs = {
        headers: Internal::Util.normalize_headers(headers), body: JSON.generate(data),
        request_id: presence(data.is_a?(Hash) ? data["request_id"] : nil)
      }
      from_detail(detail, "api_error", attrs)
    end

    # @return [String] the +error.type+ used when the body is not the error envelope
    def self.status_fallback(status)
      case status
      when 401 then "authentication_error"
      when 402 then "payment_required_error"
      when 403 then "permission_error"
      when 404 then "not_found_error"
      when 409 then "conflict_error"
      when 410 then "gone_error"
      when 429 then "limit_error"
      when 502, 503, 504 then "unavailable_error"
      when 500.. then "api_error"
      else "invalid_request_error"
      end
    end

    class << self
      private

      def presence(value)
        value.is_a?(String) && !value.empty? ? value : nil
      end

      # Returns [error detail, request id] when the body is the contract envelope, else [nil, nil].
      def envelope_of(body)
        parsed = JSON.parse(body.to_s)
        detail = parsed.is_a?(Hash) ? parsed["error"] : nil
        return [nil, nil] unless detail.is_a?(Hash) && detail["type"].is_a?(String) && detail["message"].is_a?(String)

        [detail, presence(parsed["request_id"])]
      rescue JSON::ParserError, EncodingError
        [nil, nil]
      end

      def from_detail(detail, fallback, attrs)
        type = detail["type"]
        klass = ERROR_CLASSES[type] || ERROR_CLASSES.fetch(fallback)
        code = detail["code"]
        fields = detail["fields"]
        fields = fields.is_a?(Array) ? fields.grep(Hash).map { |f| Models::FieldError.from_wire(f) } : []
        klass.new(
          **attrs,
          type: type, api_message: detail["message"], code: code.is_a?(String) ? code : nil,
          fields: fields, extra: detail.except("type", "message", "code", "fields"), envelope: true
        )
      end
    end

    private

    def describe
      text = @api_message
      text = "The API returned an error without a readable body" if text.nil? || text.empty?
      details = []
      details << "status #{@status}" if @status
      details << "type #{@type}"
      details << "code #{@code}" if @code
      details << "request_id #{@request_id}" if @request_id
      "#{text} (#{details.join(", ")})"
    end
  end

  # +invalid_request_error+: the request is malformed or failed validation (400, 413, 422, ...).
  class InvalidRequestError < APIError; end
  # +authentication_error+: the API key is missing, invalid, expired or revoked (401).
  class AuthenticationError < APIError; end
  # +payment_required_error+: the balance is exhausted or the feature is not paid for (402).
  class PaymentRequiredError < APIError; end
  # +permission_error+: the key lacks a permission (403).
  class PermissionError < APIError; end
  # +not_found_error+: the resource does not exist (404).
  class NotFoundError < APIError; end
  # +conflict_error+: the request conflicts with the current state (409).
  class ConflictError < APIError; end
  # +gone_error+: the resource existed but is no longer available (410).
  class GoneError < APIError; end
  # +limit_error+: a rate limit or a plan limit was reached (429).
  class LimitError < APIError; end
  # +api_error+: an unexpected failure on the Tungo side (500).
  class ServerError < APIError; end
  # +unavailable_error+: the service or one of its dependencies is temporarily unavailable (502, 503, 504).
  class UnavailableError < APIError; end

  class APIError
    # Maps +error.type+ to the error class.
    ERROR_CLASSES = {
      "invalid_request_error" => InvalidRequestError,
      "authentication_error" => AuthenticationError,
      "payment_required_error" => PaymentRequiredError,
      "permission_error" => PermissionError,
      "not_found_error" => NotFoundError,
      "conflict_error" => ConflictError,
      "gone_error" => GoneError,
      "limit_error" => LimitError,
      "api_error" => ServerError,
      "unavailable_error" => UnavailableError
    }.freeze
  end
end
