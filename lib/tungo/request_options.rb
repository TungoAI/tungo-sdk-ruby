# frozen_string_literal: true

module Tungo
  # Per-request overrides. Every resource method takes +request_options:+ as a Hash with the
  # same keys or as an instance of this class.
  #
  # @!attribute timeout
  #   @return [Numeric, nil] seconds for the whole request, including reading the body
  # @!attribute max_retries
  #   @return [Integer, nil] how many times a failed request may be repeated
  # @!attribute idempotency_key
  #   @return [String, nil] value of the Idempotency-Key header (generated when the operation declares it)
  # @!attribute extra_headers
  #   @return [Hash{String=>String}, nil] headers added to (or replacing) the default ones
  # @!attribute connect_timeout
  #   @return [Numeric, nil] seconds to establish the connection of a streaming call
  # @!attribute idle_timeout
  #   @return [Numeric, nil] seconds a streaming call may stay silent
  RequestOptions = Data.define(:timeout, :max_retries, :idempotency_key, :extra_headers, :connect_timeout,
                               :idle_timeout) do
    def initialize(timeout: nil, max_retries: nil, idempotency_key: nil, extra_headers: nil, connect_timeout: nil,
                   idle_timeout: nil)
      self.class.check_seconds(:timeout, timeout)
      self.class.check_seconds(:connect_timeout, connect_timeout)
      self.class.check_seconds(:idle_timeout, idle_timeout)
      unless max_retries.nil? || (max_retries.is_a?(Integer) && !max_retries.negative?)
        raise ValidationError, "max_retries must be a non-negative Integer"
      end
      unless idempotency_key.nil? || (idempotency_key.is_a?(String) && !idempotency_key.empty?)
        raise ValidationError, "idempotency_key must be a non-empty String"
      end

      super(timeout:, max_retries:, idempotency_key:, extra_headers: extra_headers&.to_h&.freeze, connect_timeout:,
            idle_timeout:)
    end

    # @param value [Tungo::RequestOptions, Hash, nil]
    # @return [Tungo::RequestOptions]
    def self.coerce(value)
      case value
      when RequestOptions then value
      when nil then new
      when Hash then new(**value.transform_keys(&:to_sym))
      else raise ValidationError, "request_options must be a Hash or a Tungo::RequestOptions, got #{value.class}"
      end
    rescue ArgumentError => e
      raise ValidationError, "invalid request_options: #{e.message}"
    end

    # @api private
    def self.check_seconds(name, value)
      return if value.nil? || (value.is_a?(Numeric) && value.positive? && value.to_f.finite?)

      raise ValidationError, "#{name} must be a positive number of seconds"
    end
  end
end
