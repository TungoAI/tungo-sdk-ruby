# frozen_string_literal: true

require_relative "test_helper"

class WebhooksTest < TungoTestCase
  SECRET = "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
  BODY = '{"id":"evt_1","type":"proposal.written","created_at":"2026-11-09T15:00:00.000Z",' \
         '"workspace_id":"ws_1","company_id":"co_1","data":{"proposal_id":"P-000042","kind":"Счёт"}}'

  def signed(body: BODY, timestamp: Time.now.to_i, id: "msg_1", prefix: "webhook")
    key = Base64.strict_decode64(SECRET.delete_prefix("whsec_"))
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "#{id}.#{timestamp}.#{body}"))
    { "#{prefix}-id" => id, "#{prefix}-timestamp" => timestamp.to_s, "#{prefix}-signature" => "v1,#{signature}" }
  end

  def test_verifies_against_the_system_clock_by_default
    event = Tungo::Webhooks.verify_webhook(BODY, signed, SECRET)

    assert_instance_of Tungo::Models::WebhookEventProposalWritten, event
    assert_equal "P-000042", event.data.proposal_id
  end

  def test_old_message_is_rejected_with_the_system_clock
    error = assert_raises(Tungo::WebhookVerificationError) do
      Tungo::Webhooks.verify_webhook(BODY, signed(timestamp: Time.now.to_i - 3600), SECRET)
    end

    assert_equal :timestamp_too_old, error.reason
  end

  def test_now_accepts_a_time
    headers = signed(timestamp: 1_793_974_568)

    assert Tungo::Webhooks.verify_webhook(BODY, headers, SECRET, now: Time.at(1_793_974_600))
  end

  def test_header_containers
    headers = signed
    rack = headers.to_h { |name, value| ["HTTP_#{name.upcase.tr("-", "_")}", value] }.merge("rack.input" => nil)
    upper = headers.transform_keys(&:upcase)
    symbols = headers.transform_keys { |name| name.tr("-", "_").to_sym }
    arrays = headers.transform_values { |value| [value] }
    message = Net::HTTP::Post.new("/")
    headers.each { |name, value| message[name] = value }

    [rack, upper, symbols, arrays, message, signed(prefix: "svix")].each do |container|
      assert_kind_of Tungo::Model, Tungo::Webhooks.verify_webhook(BODY, container, SECRET), container.class.name
    end
  end

  def test_several_signatures_any_may_match
    headers = signed
    headers["webhook-signature"] = "v1,AAAA v2,zzz #{headers["webhook-signature"]}"

    assert Tungo::Webhooks.verify_webhook(BODY, headers, SECRET)
  end

  def test_bad_input_raises_the_typed_error_never_a_raw_exception
    headers = signed
    bad = [
      [BODY, headers, nil], [BODY, headers, 42], [BODY, headers, "whsec_***"], [BODY, headers, ""],
      [nil, headers, SECRET], [BODY, nil, SECRET], [BODY, 42, SECRET], [BODY, {}, SECRET],
      [BODY, headers.merge("webhook-signature" => "\xFF\xFE".b), SECRET],
      [BODY, headers.merge("webhook-timestamp" => "soon"), SECRET],
      ["#{BODY} ", headers, SECRET], ["\xFF".b, headers, SECRET]
    ]
    bad.each do |payload, container, secret|
      error = assert_raises(Tungo::WebhookVerificationError) do
        Tungo::Webhooks.verify_webhook(payload, container, secret)
      end
      assert_kind_of Symbol, error.reason
    end
    assert_raises(Tungo::WebhookVerificationError) { Tungo::Webhooks.verify_webhook(BODY, headers, SECRET, tolerance: 0) }
  end

  def test_signed_payload_that_is_not_an_event
    body = "[1,2,3]"
    error = assert_raises(Tungo::WebhookVerificationError) do
      Tungo::Webhooks.verify_webhook(body, signed(body: body), SECRET)
    end

    assert_equal :invalid_payload, error.reason
  end

  def test_unknown_event_type_is_returned_as_unknown_variant
    body = '{"id":"evt_2","type":"galaxy.created","data":{}}'
    event = Tungo::Webhooks.verify_webhook(body, signed(body: body), SECRET)

    assert_instance_of Tungo::UnknownVariant, event
    assert_equal "galaxy.created", event[:type]
  end

  def test_client_helper_uses_the_configured_secret
    configured = client(webhook_secret: SECRET)

    assert_instance_of Tungo::Models::WebhookEventProposalWritten, configured.verify_webhook(BODY, signed)
    assert configured.verify_webhook(BODY, signed, secret: SECRET)
    error = assert_raises(Tungo::WebhookVerificationError) { client.verify_webhook(BODY, signed) }

    assert_equal :invalid_secret, error.reason
  end

  def test_every_known_event_type_has_a_model
    assert_equal 22, Tungo::WEBHOOK_EVENT_TYPES.size
    assert_equal Tungo::WEBHOOK_EVENT_TYPES.sort, Tungo::Models::WebhookEvent.mapping.keys.sort
  end

  def test_constant_time_comparison_is_used
    source = File.read(File.join(ROOT, "lib/tungo/internal/util.rb"))

    assert_includes source, "OpenSSL.fixed_length_secure_compare"
    assert Tungo::Internal::Util.secure_compare("abc", "abc")
    refute Tungo::Internal::Util.secure_compare("abc", "abd")
    refute Tungo::Internal::Util.secure_compare("abc", "abcd")
  end

  def test_hook_signature_helpers
    signature = Tungo::Webhooks.sign_hook_payload("{}", "hksec_1")

    assert_match(/\Asha256=[0-9a-f]{64}\z/, signature)
    assert Tungo::Webhooks.verify_hook_signature("{}", signature, "hksec_1")
    assert Tungo::Webhooks.verify_hook_signature("{}", signature.upcase, "hksec_1")
    refute Tungo::Webhooks.verify_hook_signature("{} ", signature, "hksec_1")
    refute Tungo::Webhooks.verify_hook_signature("{}", nil, "hksec_1")
    refute Tungo::Webhooks.verify_hook_signature("{}", "\xFF".b, "hksec_1")
  end
end
