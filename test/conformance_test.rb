# frozen_string_literal: true

require_relative "test_helper"

# Runs every section of the shared conformance vectors (conformance/vectors.json, version 2)
# against the SDK. The vectors are the same for all Tungo SDKs.
class ConformanceTest < TungoTestCase
  ERROR_TYPES = Tungo::APIError::ERROR_CLASSES

  def test_vector_version_and_sections
    assert_equal 2, vectors["version"]
    sections = vectors.keys - %w[version description]
    covered = %w[webhook_verification hook_signature money bin_iin errors retry_after backoff retry_policy
                 path_segment query sse chat_stream chat_stream_replay]

    assert_equal covered.sort, sections.sort, "a vector section has no test"
  end

  def test_webhook_verification
    section = vectors["webhook_verification"]

    assert_equal section["default_tolerance_seconds"], Tungo::Webhooks::DEFAULT_TOLERANCE
    section["cases"].each do |kase|
      options = { now: kase["now"] }
      options[:tolerance] = kase["tolerance_seconds"] if kase.key?("tolerance_seconds")
      verify = -> { Tungo::Webhooks.verify_webhook(kase["body"], kase["headers"], kase["secret"], **options) }
      if kase["expect"]["valid"]
        assert_equal kase["expect"]["event_type"], verify.call.type, kase["name"]
      else
        error = assert_raises(Tungo::WebhookVerificationError, kase["name"]) { verify.call }
        assert_equal kase["expect"]["reason"], error.reason.to_s, kase["name"] if kase["expect"]["reason"]
      end
    end
  end

  def test_hook_signature_sign
    vectors["hook_signature"]["sign"].each do |kase|
      body = Base64.strict_decode64(kase["body_base64"])
      if kase["expect"]["error"]
        assert_raises(Tungo::ValidationError, kase["name"]) { Tungo::Webhooks.sign_hook_payload(body, kase["secret"]) }
      else
        assert_equal kase["expect"]["hex"], Tungo::Webhooks.hook_signature(body, kase["secret"]), kase["name"]
        assert_equal kase["expect"]["header"], Tungo::Webhooks.sign_hook_payload(body, kase["secret"]), kase["name"]
      end
    end
  end

  def test_hook_signature_verify
    vectors["hook_signature"]["verify"].each do |kase|
      body = Base64.strict_decode64(kase["body_base64"])
      actual = Tungo::Webhooks.verify_hook_signature(body, kase["signature"], kase["secret"])

      assert_equal kase["expect"]["valid"], actual, kase["name"]
    end
  end

  def test_money_to_tiyn
    vectors["money"]["to_tiyn"].each do |kase|
      check_tiyn(kase) { Tungo::Money.to_tiyn(kase["input"]) }
    end
  end

  def test_money_to_tiyn_float
    specials = { "NaN" => Float::NAN, "Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY }
    vectors["money"]["to_tiyn_float"].each do |kase|
      input = kase.key?("special") ? specials.fetch(kase["special"]) : kase["input"].to_f
      check_tiyn(kase) { Tungo::Money.to_tiyn(input) }
    end
  end

  def test_money_to_tiyn_bounds_a_huge_exponent
    # A BigDecimal parsed from user text may carry any exponent: it is never written out in full.
    { "1E-999999999" => 0, "-1E-999999999" => 0, "0E-999999999" => 0, "9.99E-4" => 0, "5E-3" => 1,
      "-5E-3" => -1, "1.005E2" => 10_050 }.each do |text, tiyn|
      assert_equal tiyn, Tungo::Money.to_tiyn(BigDecimal(text)), text
    end
    %w[1E+999999999 -1E19].each do |text|
      assert_raises(Tungo::MoneyError, text) { Tungo::Money.to_tiyn(BigDecimal(text)) }
    end
  end

  def test_money_format_tiyn
    vectors["money"]["format_tiyn"].each do |kase|
      arguments = [Integer(kase["tiyn"])]
      arguments << kase["currency"] if kase.key?("currency")

      assert_equal kase["expect"]["text"], Tungo::Money.format_tiyn(*arguments), kase["name"]
    end
  end

  def test_bin_iin
    vectors["bin_iin"].each do |kase|
      assert_equal kase["expect"]["valid"], Tungo::Money.valid_bin_iin?(kase["input"]), kase["name"]
    end
  end

  def test_errors
    vectors["errors"]["cases"].each do |kase|
      error = Tungo::APIError.from_response(status: kase["status"], headers: kase["headers"], body: kase["body"])
      check_error(error, kase)
    end
  end

  def test_errors_through_the_client
    vectors["errors"]["cases"].each do |kase|
      server.respond { |_| { status: kase["status"], headers: kase["headers"], body: kase["body"] } }
      error = assert_raises(Tungo::APIError, kase["name"]) do
        client(max_retries: 0).companies.list
      end
      # The mock adds an x-request-id header of its own; the body's request id still wins.
      check_error(error, kase, request_id: kase["expect"]["request_id"] || "req_hdr_1")
    end
  end

  def test_errors_status_fallback
    vectors["errors"]["status_fallback"].each do |kase|
      type = kase["expect"]["type"]

      assert_equal type, Tungo::APIError.status_fallback(kase["status"]), "status #{kase["status"]}"
      error = Tungo::APIError.from_response(status: kase["status"], headers: {}, body: "<html>oops</html>")

      assert_instance_of ERROR_TYPES.fetch(type), error
      refute_predicate error, :envelope?
    end
  end

  def test_retry_after
    section = vectors["retry_after"]

    assert_equal section["max_sleep_seconds"], Tungo::Internal::Util::MAX_RETRY_AFTER_SECONDS
    section["cases"].each do |kase|
      seconds = Tungo::Internal::Util.parse_retry_after(kase["headers"], now: Time.iso8601(kase["now"]))
      expected = kase["expect"]["seconds"]
      if expected.nil?
        assert_nil seconds, kase["name"]
      else
        assert_in_delta expected, seconds, 1e-9, kase["name"]
      end
      sleeps = seconds.nil? || seconds <= section["max_sleep_seconds"]

      assert_equal kase["expect"]["sleep"], sleeps, kase["name"]
    end
  end

  def test_backoff
    section = vectors["backoff"]
    util = Tungo::Internal::Util

    assert_in_delta section["base_seconds"], util::RETRY_BASE_SECONDS
    assert_in_delta section["max_seconds"], util::RETRY_MAX_SECONDS
    assert_in_delta section["jitter_min"], util::RETRY_JITTER.begin
    assert_in_delta section["jitter_max"], util::RETRY_JITTER.end
    section["cases"].each do |kase|
      range = (kase["expect"]["min_seconds"]..kase["expect"]["max_seconds"])
      50.times { assert_includes range, util.backoff_delay(kase["attempt"]), kase["name"] }
    end
  end

  def test_retry_policy
    vectors["retry_policy"].each do |kase|
      cause = kase["cause"].is_a?(String) ? kase["cause"].to_sym : kase["cause"]
      actual = Tungo::Internal::Util.retryable?(kase["method"], kase["idempotency_key"], cause)

      assert_equal kase["expect"]["retry"], actual, kase["name"]
    end
  end

  def test_path_segment
    vectors["path_segment"].each do |kase|
      if kase["expect"]["error"]
        assert_raises(Tungo::ValidationError, kase["name"]) { Tungo::Internal::Util.encode_path_segment(kase["input"]) }
      else
        assert_equal kase["expect"]["encoded"], Tungo::Internal::Util.encode_path_segment(kase["input"]), kase["name"]
      end
    end
  end

  def test_path_segment_on_the_wire
    vectors["path_segment"].each do |kase|
      next if kase["expect"]["error"]

      client.chat.get(kase["input"], company_id: "co_1")

      assert_equal "/v1/companies/co_1/chat/#{kase["expect"]["encoded"]}", server.requests.last.target, kase["name"]
    end
  end

  def test_query
    vectors["query"].each do |kase|
      params = kase["params"].map { |param| [param["name"], query_value(param)] }
      actual = Tungo::Internal::Util.encode_query(params)
      allowed = kase["expect"]["any_of"] || [kase["expect"]["query"]]

      assert_includes allowed, actual, kase["name"]
    end
  end

  def test_sse
    vectors["sse"].each do |kase|
      raw = Base64.strict_decode64(kase["raw_base64"])
      chunkings = [[raw], raw.each_char.to_a, raw.bytes.map { |byte| byte.chr.b }]
      chunkings << kase["chunks_base64"].map { |chunk| Base64.strict_decode64(chunk) } if kase["chunks_base64"]
      chunkings.each_with_index do |chunks, index|
        assert_equal sse_rows(kase["expect"]["events"]), decode_sse(chunks), "#{kase["name"]} (chunking #{index})"
      end
    end
  end

  def test_chat_stream
    vectors["chat_stream"].each do |kase|
      server.respond { |_| { status: kase["status"], headers: kase["headers"], chunks: [kase["raw"]] } }
      stream = client.chat.create_stream(message: "Привет", company_id: "co_1")
      unless kase["raw"].match?(/^event: (done|error)$/)
        # A stream that ends with neither "done" nor "error" is cut: it is never a finished turn.
        error = assert_raises(Tungo::DecodeError, kase["name"]) { stream.accumulate(raise_on_error: false) }

        assert_match(/ended before completion/, error.message, kase["name"])
        next
      end
      turn = stream.accumulate(raise_on_error: false)
      check_chat_turn(turn, kase)
      check_chat_error(kase)
    end
  end

  # A stream call repeated with the same Idempotency-Key after its turn finished is answered with
  # the stored ChatTurnResult as JSON: the stream must yield the events of that turn.
  def test_chat_stream_replay
    vectors["chat_stream_replay"].each do |kase|
      server.respond { |_| { status: kase["status"], headers: kase["headers"], chunks: [JSON.generate(kase["body"])] } }
      if kase["expect"]["decode_error"]
        error = assert_raises(Tungo::DecodeError, kase["name"]) do
          client.chat.create_stream(message: "Привет", company_id: "co_1")
        end

        assert_equal kase["status"], error.api_response.status, kase["name"]
        next
      end
      turn = client.chat.create_stream(message: "Привет", company_id: "co_1").accumulate(raise_on_error: false)
      check_chat_turn(turn, kase)
      check_chat_error(kase)
    end
  end

  private

  def check_tiyn(kase, &)
    if kase["expect"]["error"]
      assert_raises(Tungo::MoneyError, kase["name"], &)
    else
      assert_equal Integer(kase["expect"]["tiyn"]), yield, kase["name"]
    end
  end

  def check_error(error, kase, request_id: kase["expect"]["request_id"])
    expect = kase["expect"]
    name = kase["name"]

    assert_instance_of ERROR_TYPES.fetch(expect["class"]), error, name
    assert_equal kase["status"], error.status, name
    assert_equal expect["envelope"], error.envelope?, name
    assert_equal expect["type"], error.type, name
    assert_nil_or_equal expect["code"], error.code, name
    assert_equal expect["message"], error.api_message, name if expect.key?("message")
    assert_nil_or_equal request_id, error.request_id, name
    assert_nil_or_equal expect["retry_after"], error.retry_after, name
    assert_equal expect["fields"], error.fields.map { |field| field.to_wire.slice("path", "code", "message") }, name
    assert_equal expect["extra"], error.extra, name
    assert_equal kase["body"], error.body, name
    refute_empty error.message, name
  end

  def assert_nil_or_equal(expected, actual, message)
    if expected.nil?
      assert_nil actual, message
    else
      assert_equal expected, actual, message
    end
  end

  def query_value(param)
    value = param["value"]
    return value if value.nil?

    case param["type"]
    when "integer" then Integer(value)
    when "date-time" then Time.iso8601(value)
    else value
    end
  end

  # In the vectors an empty id and no id are the same.
  def sse_rows(events)
    events.map { |event| event.merge("id" => event["id"].to_s.empty? ? nil : event["id"]) }
  end

  def decode_sse(chunks)
    decoder = Tungo::Internal::SSEDecoder.new
    events = []
    collect = ->(event) { events << event }
    chunks.each { |chunk| decoder.feed(chunk, &collect) }
    decoder.finish(&collect)
    events.map do |event|
      row = { "event" => event.event, "data" => event.data, "id" => event.id.to_s.empty? ? nil : event.id }
      row["retry"] = event.retry unless event.retry.nil?
      row
    end
  end

  def check_chat_turn(turn, kase)
    expect = kase["expect"]
    name = kase["name"]

    assert_nil_or_equal expect["dialog_id"], turn.dialog_id, name
    assert_nil_or_equal expect["turn_no"], turn.turn_no, name
    assert_equal expect["text"], turn.text, name
    assert_nil_or_equal expect["stop_reason"], turn.stop_reason, name
    assert_nil_or_equal expect["cost_tiyn"], turn.cost_tiyn, name
    assert_nil_or_equal expect["usage"], turn.usage && Tungo::Internal::Type.wire(turn.usage), name
    assert_nil_or_equal expect["choice_id"], turn.choice_id, name
    assert_equal expect["event_count"], turn.events.size, name
    assert_equal expect["event_types"], turn.events.map { |event| event[:type] }, name if expect["event_types"]
    assert_equal expect["error"].nil?, turn.error.nil?, name
    check_chat_next(turn, kase)
  end

  # The followups and action of the next event, when the vector names them.
  def check_chat_next(turn, kase)
    return unless kase["expect"].key?("next")

    nexts = turn.events.select { |event| event[:type] == "next" }.map do |event|
      wire = Tungo::Internal::Type.wire(event)
      { "followups" => wire["followups"], "action" => wire["action"] }
    end

    assert_equal [kase["expect"]["next"]], nexts, kase["name"]
  end

  # The accumulating helpers must raise the error event as a typed error.
  def check_chat_error(kase)
    expected = kase["expect"]["error"]
    stream = client.chat.create_stream(message: "Привет", company_id: "co_1")
    if expected.nil?
      stream.accumulate
      return
    end
    error = assert_raises(Tungo::APIError, kase["name"]) { stream.accumulate }

    assert_instance_of ERROR_TYPES.fetch(expected["type"], Tungo::ServerError), error, kase["name"]
    assert_equal expected["type"], error.type, kase["name"]
    assert_nil_or_equal expected["code"], error.code, kase["name"]
    assert_equal expected["message"], error.api_message, kase["name"]
    assert_nil_or_equal expected["request_id"], error.request_id, kase["name"]
    assert_equal expected["extra"] || {}, error.extra, kase["name"]
  end
end
