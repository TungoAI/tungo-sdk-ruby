# frozen_string_literal: true

# Verify an incoming webhook and send an event to an incoming hook.
#
#   TUNGO_WEBHOOK_SECRET=whsec_... ruby examples/webhooks.rb

require "tungo"

client = Tungo::Client.new

# What your endpoint receives: the raw body and the request headers. Here a message is signed
# locally to make the example self-contained.
secret = ENV.fetch("TUNGO_WEBHOOK_SECRET")
payload = '{"id":"evt_1","type":"proposal.written","created_at":"2026-11-09T15:00:00.000Z",' \
          '"workspace_id":"ws_1","company_id":"co_1","data":{"proposal_id":"P-000042","kind":"Счёт"}}'
timestamp = Time.now.to_i
key = Base64.strict_decode64(secret.delete_prefix("whsec_"))
signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "msg_1.#{timestamp}.#{payload}"))
headers = { "webhook-id" => "msg_1", "webhook-timestamp" => timestamp.to_s, "webhook-signature" => "v1,#{signature}" }

begin
  event = client.verify_webhook(payload, headers)
  case event
  when Tungo::Models::WebhookEventProposalWritten
    puts "Proposal #{event.data.proposal_id} was written"
  else
    puts "Unhandled event #{event[:type]}"
  end
rescue Tungo::WebhookVerificationError => e
  warn "Rejected: #{e.message} (#{e.reason})"
  exit 1
end

# Send an event to an incoming hook, signed with the hook's secret. The API key is not sent.
accepted = client.send_hook("th_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                            { id: "order_1532", amount_tiyn: Tungo::Money.to_tiyn("45000.00") },
                            secret: "hksec_example", event_id: "order_1532")
puts "accepted as #{accepted.event_id}"
client.close
