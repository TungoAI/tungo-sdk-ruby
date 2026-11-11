# frozen_string_literal: true

module Tungo
  # Verification of outgoing webhooks (Standard Webhooks / Svix) and signing of incoming hooks.
  module Webhooks
    # Allowed clock difference between the sender and the receiver, in seconds.
    DEFAULT_TOLERANCE = 300
    SECRET_PREFIX = "whsec_"
    HOOK_SIGNATURE_PREFIX = "sha256="

    module_function

    # Verifies a webhook and returns its typed event.
    #
    # The signed text is +id.timestamp.body+, the key is the base64-decoded part of the secret
    # after +whsec_+. Both +webhook-*+ and +svix-*+ headers are accepted, in any case and from
    # any container (a Hash, a Rack env, Rack/Rails headers, a Net::HTTP message).
    #
    # @param payload [String] the raw request body, exactly as received
    # @param headers [#each] the request headers
    # @param secret [String] the endpoint's signing secret (+whsec_...+)
    # @param tolerance [Numeric] allowed clock difference in seconds, in both directions
    # @param now [Time, Integer, nil] the clock to compare with; the system clock by default
    # @return [Tungo::Model] one of the {Tungo::Models::WebhookEvent} variants
    # @raise [Tungo::WebhookVerificationError] for every reason the webhook cannot be trusted
    def verify_webhook(payload, headers, secret, tolerance: DEFAULT_TOLERANCE, now: nil)
      fail!(:invalid_tolerance, "tolerance must be a positive number of seconds") unless positive_number?(tolerance)
      fail!(:invalid_payload, "payload must be the raw request body as a String") unless payload.is_a?(String)

      key = signing_key(secret)
      id, timestamp, signatures = signature_headers(headers)
      check_timestamp(timestamp, now.nil? ? Time.now.to_i : now.to_i, tolerance)
      expected = OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.".b + payload.b)
      fail!(:signature_mismatch, "no signature matches the payload") unless signature_matches?(signatures, expected)

      parse_event(payload)
    end

    # Signs the body of an incoming hook.
    #
    # @param body [String] the exact bytes that will be sent
    # @param secret [String] the hook's secret
    # @return [String] the value of the +X-Signature+ header: "sha256=<hex>"
    # @raise [Tungo::ValidationError] when the secret is empty
    def sign_hook_payload(body, secret)
      "#{HOOK_SIGNATURE_PREFIX}#{hook_signature(body, secret)}"
    end

    # @param body [String] the exact bytes that will be sent
    # @param secret [String] the hook's secret
    # @return [String] HMAC-SHA256 of the body as lower-case hex
    # @raise [Tungo::ValidationError] when the secret is empty
    def hook_signature(body, secret)
      raise ValidationError, "the hook secret must be a non-empty String" unless secret.is_a?(String) && !secret.empty?
      raise ValidationError, "the hook body must be a String" unless body.is_a?(String)

      OpenSSL::HMAC.hexdigest("SHA256", secret, body.b)
    end

    # Checks the signature of an incoming hook in constant time. The signature may be upper- or
    # lower-case hex, with or without the +sha256=+ prefix.
    #
    # @return [Boolean] false for an empty secret, an empty or malformed signature, or a mismatch
    def verify_hook_signature(body, signature, secret)
      return false unless body.is_a?(String) && signature.is_a?(String) && secret.is_a?(String) && !secret.empty?

      given = signature.b.strip
      prefix = HOOK_SIGNATURE_PREFIX
      given = given[prefix.size..] if given[0, prefix.size].to_s.casecmp?(prefix)
      Internal::Util.secure_compare(hook_signature(body, secret), given.downcase)
    end

    # @api private
    def fail!(reason, message)
      raise WebhookVerificationError.new("Webhook verification failed: #{message}", reason: reason)
    end

    # @api private
    def positive_number?(value)
      value.is_a?(Numeric) && value.positive? && value.to_f.finite?
    end

    # @api private
    def signing_key(secret)
      fail!(:invalid_secret, "the signing secret is missing") unless secret.is_a?(String) && !secret.empty?

      key = Base64.strict_decode64(secret.delete_prefix(SECRET_PREFIX))
      fail!(:invalid_secret, "the signing secret is empty") if key.empty?
      key
    rescue ArgumentError
      fail!(:invalid_secret, "the signing secret is not valid base64")
    end

    # @api private
    def signature_headers(headers)
      found = normalize(headers)
      values = %w[id timestamp signature].map { |name| found["svix-#{name}"] || found["webhook-#{name}"] }
      fail!(:missing_header, "the id, timestamp and signature headers are required") if values.any?(&:nil?)
      values
    end

    # Accepts "Svix-Id", :svix_id and the Rack form "HTTP_SVIX_ID" alike.
    # @api private
    def normalize(headers)
      fail!(:missing_header, "headers must be a collection of name/value pairs") unless headers.respond_to?(:each)

      found = {}
      headers.each do |name, value|
        key = name.to_s.downcase.tr("_", "-").delete_prefix("http-")
        value = value.first if value.is_a?(Array)
        found[key] = value.to_s if key.start_with?("svix-", "webhook-") && !value.nil?
      end
      found
    end

    # @api private
    def check_timestamp(timestamp, now, tolerance)
      unless timestamp.b.match?(/\A[0-9]+\z/)
        fail!(:malformed_timestamp,
              "the timestamp header is not a number of seconds")
      end

      sent = timestamp.to_i
      fail!(:timestamp_too_old, "the message is older than the tolerance") if now - sent > tolerance
      fail!(:timestamp_too_new, "the message is newer than the tolerance") if sent - now > tolerance
    end

    # @api private
    def signature_matches?(signatures, expected)
      matched = false
      signatures.b.split.each do |entry|
        version, value = entry.split(",", 2)
        next unless version == "v1" && value

        candidate = begin
          Base64.strict_decode64(value)
        rescue ArgumentError
          next
        end
        matched = true if Internal::Util.secure_compare(expected, candidate)
      end
      matched
    end

    # @api private
    def parse_event(payload)
      data = Internal::Util.parse_json(payload)
      fail!(:invalid_payload, "the payload is not a JSON object") unless data.is_a?(Hash)

      Models::WebhookEvent.coerce(data)
    rescue JSON::ParserError, EncodingError
      fail!(:invalid_payload, "the payload is not valid JSON")
    end
  end
end
