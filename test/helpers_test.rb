# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

class HelpersTest < TungoTestCase
  def scoped(**)
    client(company_id: "co_1", **)
  end

  def turn(extra = {})
    { "answer" => "НДС 5 400 ₸", "dialog_id" => "dlg_1", "turn_no" => 2, "errors" => [], "citations" => [],
      "proposals" => [], "questions" => [], "pending_question" => nil, "stop_reason" => "end_turn" }.merge(extra)
  end

  def test_ask_returns_the_typed_turn
    server.respond { |_| MockServer.json(turn, headers: { "X-Dialog-Id" => "dlg_1" }) }
    result = scoped.ask("Сколько НДС?")

    assert_instance_of Tungo::Models::ChatTurnResult, result
    assert_equal "НДС 5 400 ₸", result.answer
    assert_equal "dlg_1", result.dialog_id
    assert_equal({ "message" => "Сколько НДС?", "stream" => false }, server.requests.last.json)
    assert_equal "application/json", server.requests.last.headers["accept"]
  end

  def test_ask_continues_a_dialog
    server.respond { |_| MockServer.json(turn) }
    scoped.ask("Ещё", dialog_id: "dlg_1", company_id: "co_2")

    assert_equal "dlg_1", server.requests.last.json["dialog_id"]
    assert_equal "/v1/companies/co_2/chat", server.requests.last.path
  end

  def test_ask_raises_the_turn_error
    failed = turn("errors" => [{ "type" => "limit_error", "code" => "budget", "message" => "Лимит исчерпан" }])
    server.respond { |_| MockServer.json(failed) }
    error = assert_raises(Tungo::LimitError) { scoped.ask("x") }

    assert_equal "budget", error.code
    assert_equal "Лимит исчерпан", error.api_message
    assert_equal "req_hdr_1", error.request_id
    assert_equal "limit_error", scoped.ask("x", raise_on_error: false).errors.first.type
  end

  def test_send_hook_signs_the_exact_bytes
    server.respond do |_|
      MockServer.json({ "event_id" => "evt_1", "duplicate" => false, "run_ids" => ["run_1"] }, status: 202)
    end
    body = '{"id": "order_1",  "amount_tiyn": 4500000}'
    accepted = client.send_hook("th_token", body, secret: "hksec_1", event_id: "evt_1")
    request = server.requests.last

    assert_instance_of Tungo::Models::AutomationHookAccepted, accepted
    assert_equal ["run_1"], accepted.run_ids
    assert_equal "/hooks/th_token", request.path
    assert_equal body, request.body
    assert_equal Tungo::Webhooks.sign_hook_payload(body, "hksec_1"), request.headers["x-signature"]
    assert_equal "evt_1", request.headers["x-event-id"]
    assert_equal "evt_1", request.headers["idempotency-key"]
    assert_nil request.headers["x-api-key"]
  end

  def test_send_hook_with_a_hash_sends_json
    client.send_hook("th_token", { id: "order_1", note: "Оплата" }, secret: "hksec_1")
    request = server.requests.last

    assert_equal "application/json", request.headers["content-type"]
    assert_equal({ "id" => "order_1", "note" => "Оплата" }, request.json)
    assert_equal Tungo::Webhooks.sign_hook_payload(request.body, "hksec_1"), request.headers["x-signature"]
    assert_match(/\A[0-9a-f-]{36}\z/, request.headers["idempotency-key"])
  end

  def test_send_hook_signs_in_the_hooks_own_signature_header
    # A hook created with signature_header "x-shop-signature" reads the signature only there.
    client.send_hook("th_token", "{}", secret: "hksec_1", signature_header: "x-shop-signature")
    request = server.requests.last

    assert_equal Tungo::Webhooks.sign_hook_payload("{}", "hksec_1"), request.headers["x-shop-signature"]
    assert_nil request.headers["x-signature"]

    client.automations.post_hook("th_token", "{}", signature: "sha256=00", signature_header: "X-Shop-Signature")

    assert_equal "sha256=00", server.requests.last.headers["x-shop-signature"]
    assert_nil server.requests.last.headers["x-signature"]
    assert_raises(Tungo::ValidationError) do
      client.automations.post_hook("th_token", "{}", secret: "hksec_1", signature: "sha256=00")
    end
    assert_raises(Tungo::ValidationError) do
      client.send_hook("th_token", "{}", secret: "hksec_1", signature_header: "bad header")
    end
  end

  def test_send_hook_without_a_secret_is_unsigned
    client.send_hook("th_token", "raw", content_type: "text/plain")

    assert_nil server.requests.last.headers["x-signature"]
    assert_equal "text/plain", server.requests.last.headers["content-type"]
    assert_equal "raw", server.requests.last.body
  end

  def test_wait_for_run_polls_until_a_terminal_state
    server.respond do |_, count|
      MockServer.json({ "id" => "run_1", "state" => %w[queued running done].fetch(count - 1) })
    end
    run = scoped.wait_for_run("run_1", poll_interval: 0.01)

    assert_instance_of Tungo::Models::AutomationRunDetail, run
    assert_equal "done", run.state
    assert_equal 3, server.requests.size
  end

  def test_every_terminal_state_ends_the_wait
    assert_equal %w[done error skipped cancelled], Tungo::Helpers::RUN_TERMINAL_STATES
    Tungo::Helpers::RUN_TERMINAL_STATES.each do |state|
      server.respond { |_| MockServer.json({ "id" => "run_1", "state" => state }) }

      assert_equal state, scoped.wait_for_run("run_1").state
    end
  end

  def test_wait_for_run_times_out
    server.respond { |_| MockServer.json({ "id" => "run_1", "state" => "running" }) }
    started = monotonic
    error = assert_raises(Tungo::WaitTimeoutError) { scoped.wait_for_run("run_1", timeout: 0.2, poll_interval: 0.05) }

    assert_operator monotonic - started, :<, 2
    assert_kind_of Tungo::TimeoutError, error
    assert_operator server.requests.size, :>, 1
  end

  def test_wait_for_run_without_a_state_fails_fast
    server.respond { |_| MockServer.json({ "id" => "run_1" }) }

    assert_raises(Tungo::DecodeError) { scoped.wait_for_run("run_1", timeout: 5) }
    assert_equal 1, server.requests.size
  end

  def test_run_scenario_and_wait
    server.respond do |request, _|
      if request.verb == "POST"
        MockServer.json({ "id" => "run_7", "state" => "queued" }, status: 202)
      else
        MockServer.json({ "id" => "run_7", "state" => "done" })
      end
    end
    run = scoped.run_scenario_and_wait("scn_1", event_id: "evt_1", poll_interval: 0.01)

    assert_equal "done", run.state
    assert_equal ["/v1/companies/co_1/automations/scenarios/scn_1/run", "/v1/companies/co_1/automations/runs/run_7"],
                 server.requests.map(&:path)
    assert_equal({ "event_id" => "evt_1" }, server.requests.first.json)
  end

  def test_wait_for_batch
    server.respond { |_, count| MockServer.json({ "id" => "b_1", "running" => count < 3 }) }
    job = scoped.wait_for_batch("b_1", poll_interval: 0.01)

    assert_instance_of Tungo::Models::BatchJob, job
    assert_equal false, job.running
    assert_equal 3, server.requests.size
    server.respond { |_| MockServer.json({ "id" => "b_1" }) }

    assert_raises(Tungo::DecodeError) { scoped.wait_for_batch("b_1") }
    assert_raises(Tungo::ValidationError) { scoped.wait_for_batch("b_1", timeout: 0) }
  end

  def test_upload_bank_statement_from_bytes_path_and_io
    bytes = "1CClientBankExchange\r\n\xC2\xE5\xF0\xF1\xE8\xFF=1.03\r\n".b
    Tempfile.create(["kl_to_1c", ".txt"]) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      scoped.upload_bank_statement(bytes, file_name: "a.txt", limit: 10)
      scoped.upload_bank_statement(Pathname(file.path))
      file.rewind
      scoped.upload_bank_statement(file)

      first, second, third = server.requests.map(&:json)

      assert_equal({ "file" => Base64.strict_encode64(bytes), "file_name" => "a.txt", "limit" => 10 }, first)
      assert_equal({ "file" => Base64.strict_encode64(bytes), "file_name" => File.basename(file.path) }, second)
      assert_equal({ "file" => Base64.strict_encode64(bytes) }, third)
    end
    assert_equal "/v1/companies/co_1/batch/bank-statement", server.requests.last.path
    assert_raises(Tungo::ValidationError) { scoped.upload_bank_statement(42) }
  end
end
