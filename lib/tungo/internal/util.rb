# frozen_string_literal: true

# The official Ruby SDK for the Tungo Platform API. Start with {Tungo::Client}.
module Tungo
  # Marks a keyword argument that was not given. It differs from +nil+, which is sent as JSON
  # +null+ wherever the API accepts it.
  OMIT = Object.new
  def OMIT.inspect
    "Tungo::OMIT"
  end
  OMIT.freeze

  # @api private
  module Internal
    # Holds a secret so that it never shows up in +inspect+, +pp+ or an exception message.
    class Secret
      def initialize(value)
        @reveal = -> { value }
        freeze
      end

      # @return [String] the secret itself
      def reveal
        @reveal.call
      end

      def inspect
        "[REDACTED]"
      end
      alias to_s inspect

      def pretty_print(printer)
        printer.text(inspect)
      end
    end

    # Request-building and retry helpers shared by the client, the transport and the tests.
    # A BigDecimal on its way into JSON: written as a plain decimal number, digit for digit.
    class DecimalNumber
      def initialize(value)
        raise ValidationError, "a JSON number must be finite, got #{value}" unless value.finite?

        @value = value
      end

      def to_json(*)
        @value.frac.zero? ? @value.to_i.to_s : @value.to_s("F")
      end
    end

    # Pure helpers shared by the client, the transport and the webhook code.
    module Util
      RETRY_BASE_SECONDS = 0.5
      RETRY_MAX_SECONDS = 8.0
      RETRY_JITTER = (0.75..1.0)
      # A server-requested delay above this is not slept: the error is raised instead.
      MAX_RETRY_AFTER_SECONDS = 60
      SAFE_METHODS = %w[GET HEAD PUT DELETE].freeze
      NUMBER = /\A[0-9]+(\.[0-9]+)?\z/
      UNRESERVED = /[^A-Za-z0-9\-._~]/n

      module_function

      # @return [Float] monotonic clock reading in seconds
      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Percent-encodes every byte outside the RFC 3986 unreserved set.
      def percent_encode(text)
        text.to_s.b.gsub(UNRESERVED) { |byte| format("%%%02X", byte.ord) }.force_encoding(Encoding::US_ASCII)
      end

      # Encodes one path parameter as a single path segment. An empty value, "." and ".." are
      # rejected because they would change which resource the request addresses.
      def encode_path_segment(value, name = "path parameter")
        text = value.is_a?(Symbol) || value.is_a?(Integer) ? value.to_s : value
        raise ValidationError, "#{name} must be a String, got #{value.class}" unless text.is_a?(String)
        raise ValidationError, "#{name} must not be empty" if text.empty?
        raise ValidationError, "#{name} must not be #{text.inspect}" if [".", ".."].include?(text)

        percent_encode(text)
      end

      # Fills a path template such as "/v1/companies/{co}/chat/{id}".
      def build_path(template, params)
        template.gsub(/\{(\w+)\}/) do
          name = Regexp.last_match(1)
          encode_path_segment(params.fetch(name.to_sym), name)
        end
      end

      # Renders one query or header value as text.
      def scalar_text(value)
        case value
        when String then value
        when Symbol, Integer, true, false then value.to_s
        when Time then value.nsec.zero? ? value.iso8601 : value.iso8601(6)
        when Date then value.iso8601
        when Float
          raise ValidationError, "a query value must be a finite number" unless value.finite?

          value.to_s
        when BigDecimal then value.to_s("F")
        else raise ValidationError, "unsupported query value of type #{value.class}"
        end
      end

      # Builds a query string. +nil+ and omitted values are left out, arrays repeat the key,
      # booleans are true/false and times are RFC 3339.
      #
      # @param params [Hash, Array<Array>] name/value pairs in order
      # @return [String] the query string without the leading "?"
      def encode_query(params)
        pairs = []
        params.each do |name, value|
          next if value.nil? || OMIT.equal?(value)

          (value.is_a?(Array) ? value : [value]).each do |item|
            next if item.nil?

            pairs << "#{percent_encode(name)}=#{percent_encode(scalar_text(item))}"
          end
        end
        pairs.join("&")
      end

      # Marks bytes received from the network as UTF-8 when they are valid UTF-8.
      def text(bytes)
        return bytes unless bytes.is_a?(String) && bytes.encoding == Encoding::BINARY

        utf8 = bytes.dup.force_encoding(Encoding::UTF_8)
        utf8.valid_encoding? ? utf8 : bytes
      end

      # Parses JSON received from the API. A number with a fraction or an exponent becomes a
      # BigDecimal, so that no amount of money ever passes through a binary float.
      def parse_json(text)
        JSON.parse(text, decimal_class: BigDecimal)
      end

      # Replaces every BigDecimal with an object that prints its exact decimal digits as a JSON number.
      def exact_numbers(value)
        case value
        when BigDecimal then DecimalNumber.new(value)
        when Hash then value.transform_values { |item| exact_numbers(item) }
        when Array then value.map { |item| exact_numbers(item) }
        else value
        end
      end

      # Lower-cases header names and joins repeated values.
      def normalize_headers(headers)
        result = {}
        (headers || {}).each do |name, value|
          value = value.join(", ") if value.is_a?(Array)
          result[name.to_s.downcase] = text(value.to_s) unless value.nil?
        end
        result
      end

      # Parses +retry-after-ms+ (wins) and +Retry-After+ (seconds or an HTTP-date).
      #
      # @return [Float, nil] seconds to wait, or nil when the headers carry no usable value
      def parse_retry_after(headers, now: Time.now)
        headers = normalize_headers(headers)
        millis = headers["retry-after-ms"]&.strip
        return millis.to_f / 1000 if millis && NUMBER.match?(millis)

        value = headers["retry-after"]&.strip
        return nil if value.nil? || value.empty?
        return value.to_f if NUMBER.match?(value)

        [Time.httpdate(value) - now, 0.0].max.to_f
      rescue ArgumentError
        nil
      end

      # Delay before retry number +attempt+ (0-based): min(0.5 s * 2^attempt, 8 s) with jitter.
      def backoff_delay(attempt, jitter: rand(RETRY_JITTER))
        [RETRY_BASE_SECONDS * (2**attempt), RETRY_MAX_SECONDS].min * jitter
      end

      # Decides whether a failed request may be repeated.
      #
      # @param method [String, Symbol] HTTP method
      # @param idempotency_key [Boolean] whether the request carries an Idempotency-Key
      # @param cause [Integer, Symbol, String] HTTP status, :connection_error or :timeout
      def retryable?(method, idempotency_key, cause)
        return false unless SAFE_METHODS.include?(method.to_s.upcase) || idempotency_key

        if cause.is_a?(Integer)
          APIError::RETRYABLE_STATUSES.include?(cause)
        else
          %w[connection_error
             timeout].include?(cause.to_s)
        end
      end

      # A secret that is sent as a header value (the API key) must be printable ASCII without
      # spaces. A trailing line break from a file or a secret store is the usual mistake; it is
      # refused here, by name only: the secret itself is never printed.
      def check_header_secret(value, name)
        return if value.valid_encoding? && value.match?(/\A[\x21-\x7E]+\z/)

        raise ConfigError, "api_key (#{name}) must be printable ASCII without spaces, line breaks or control " \
                           "characters; check it for a trailing newline. The key itself is not shown"
      end

      # Compares two strings in constant time; strings of different length are never equal.
      def secure_compare(left, right)
        left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
      end

      # Serialises a value as JSON, reporting values JSON cannot express as a validation error.
      def generate_json(value)
        JSON.generate(exact_numbers(value))
      rescue JSON::GeneratorError, EncodingError => e
        raise ValidationError, "the request body cannot be encoded as JSON: #{e.message}"
      end
    end
  end
end
