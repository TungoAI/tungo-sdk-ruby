# frozen_string_literal: true

require_relative "test_helper"

# Server-sent event streams: real incremental delivery, early termination, every streaming
# operation, errors and timeouts.
class StreamingTest < TungoTestCase
  TEXT = "id: 1\nevent: text\ndata: {\"type\":\"text\",\"delta\":\"Привет\"}\n\n"
  DONE = "id: 2\nevent: done\ndata: {\"type\":\"done\",\"stop_reason\":\"end_turn\",\"cost_tiyn\":120}\n\n"
  PING = "event: ping\ndata: \n\n"
  CHAT_HEADERS = { "X-Dialog-Id" => "dlg_1", "X-Turn-No" => "4" }.freeze

  def scoped(**)
    client(company_id: "co_1", **)
  end

  def test_events_arrive_while_the_response_is_still_open
    server.respond { |_| MockServer.sse([TEXT, TEXT, TEXT, DONE], delay: 0.4) }
    started = monotonic
    arrivals = scoped.chat.create_stream(message: "x").map { monotonic - started }

    assert_equal 4, arrivals.size
    assert_operator arrivals.first, :<, 0.35, "the first event must not wait for the end of the response"
    assert_operator arrivals.last - arrivals.first, :>, 0.8
  end

  def test_typed_chat_events
    server.respond { |_| MockServer.sse([TEXT, PING, DONE], headers: CHAT_HEADERS) }
    stream = scoped.chat.create_stream(message: "x")

    assert_instance_of Tungo::ChatStream, stream
    assert_equal "dlg_1", stream.dialog_id
    assert_equal 4, stream.turn_no
    events = stream.to_a

    assert_equal [Tungo::Models::ChatEventText, Tungo::Models::ChatEventDone], events.map(&:class)
    assert_equal "Привет", events.first.delta
    assert_equal "2", stream.last_event_id
    assert_predicate stream, :closed?
  end

  def test_request_of_a_streaming_turn
    server.respond { |_| MockServer.sse([DONE]) }
    scoped.chat.create_stream(message: "x").to_a
    request = server.requests.last

    assert_equal "text/event-stream", request.headers["accept"]
    assert_equal "identity", request.headers["accept-encoding"]
    assert_equal true, request.json["stream"]
    assert_match(/\A[0-9a-f-]{36}\z/, request.headers["idempotency-key"])
  end

  def test_unknown_event_type_is_an_unknown_variant
    server.respond { |_| MockServer.sse(["event: sparkle\ndata: {\"type\":\"sparkle\",\"level\":3}\n\n", DONE]) }
    events = scoped.chat.create_stream(message: "x").to_a

    assert_instance_of Tungo::UnknownVariant, events.first
    assert_equal 3, events.first[:level]
    assert_equal "sparkle", events.first[:type]
  end

  def test_breaking_out_closes_the_connection
    server.respond { |_| MockServer.sse([TEXT] * 200, delay: 0.02) }
    stream = scoped.chat.create_stream(message: "x")
    seen = 0
    stream.each do |_event|
      seen += 1
      break if seen == 2
    end

    assert_equal 2, seen
    assert_predicate stream, :closed?
    deadline = monotonic + 3
    sleep(0.02) until server.client_gone? || monotonic > deadline

    assert_predicate server, :client_gone?, "the server must see the client closing the connection"
  end

  def test_close_without_reading
    server.respond { |_| MockServer.sse([TEXT] * 200, delay: 0.02) }
    stream = scoped.chat.create_stream(message: "x")
    stream.close

    assert_predicate stream, :closed?
    deadline = monotonic + 3
    sleep(0.02) until server.client_gone? || monotonic > deadline

    assert_predicate server, :client_gone?
  end

  def test_a_stream_is_consumed_once
    server.respond { |_| MockServer.sse([DONE]) }
    stream = scoped.chat.create_stream(message: "x")
    stream.to_a

    assert_raises(Tungo::Error) { stream.to_a }
  end

  def test_connection_is_reused_after_a_fully_read_stream
    server.respond { |_| MockServer.sse([TEXT, DONE]) }
    shared = scoped
    shared.chat.create_stream(message: "x").to_a
    shared.chat.create_stream(message: "x").to_a

    assert_equal 1, server.connections
  end

  def test_each_text_and_accumulate
    server.respond { |_| MockServer.sse([TEXT, TEXT, DONE], headers: CHAT_HEADERS) }
    deltas = []
    turn = scoped.chat.create_stream(message: "x").each_text { |delta| deltas << delta }

    assert_equal %w[Привет Привет], deltas
    assert_instance_of Tungo::ChatTurn, turn
    assert_equal "ПриветПривет", turn.text
    assert_equal "end_turn", turn.stop_reason
    assert_equal 120, turn.cost_tiyn
    assert_equal "dlg_1", turn.dialog_id
    assert_equal 4, turn.turn_no
    assert_equal 3, turn.events.size
  end

  def test_error_event_is_raised_by_the_accumulating_helpers
    failure = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"limit_error\",\"code\":\"budget\"," \
              "\"message\":\"Лимит\"},\"request_id\":\"req_9\"}\n\n"
    server.respond { |_| MockServer.sse([TEXT, failure, DONE]) }
    events = scoped.chat.create_stream(message: "x").to_a

    assert_equal [Tungo::Models::ChatEventText, Tungo::Models::ChatEventError, Tungo::Models::ChatEventDone],
                 events.map(&:class)
    error = assert_raises(Tungo::LimitError) { scoped.chat.create_stream(message: "x").each_text { |_| nil } }

    assert_equal "budget", error.code
    assert_equal "req_9", error.request_id
    turn = scoped.chat.create_stream(message: "x").accumulate(raise_on_error: false)

    assert_instance_of Tungo::Models::ChatEventError, turn.error
  end

  def test_answer_stream
    server.respond { |_| MockServer.sse([TEXT, DONE]) }
    stream = scoped.chat.answer_stream("dlg_1", choice_id: "ch_1", answers: [{ id: "q1", value: "да" }])

    assert_instance_of Tungo::ChatStream, stream
    assert_equal 2, stream.count
    assert_equal "/v1/companies/co_1/chat/dlg_1/answer", server.requests.last.path
    assert_equal true, server.requests.last.json["stream"]
  end

  def test_chat_list_events_resumes_with_last_event_id
    server.respond { |_| MockServer.sse([TEXT, DONE]) }
    stream = scoped.chat.list_events("dlg_1", turn: 3, last_event_id: "17")

    assert_instance_of Tungo::ChatStream, stream
    assert_equal 2, stream.count
    request = server.requests.last

    assert_equal "GET", request.verb
    assert_equal "/v1/companies/co_1/chat/dlg_1/events", request.path
    assert_equal "turn=3", request.query
    assert_equal "17", request.headers["last-event-id"]
    assert_nil request.headers["idempotency-key"]
  end

  def test_batches_list_events
    batch = "event: batch\ndata: {\"type\":\"batch\",\"batch_id\":\"b_1\"}\n\n"
    server.respond { |_| MockServer.sse([batch, DONE]) }
    events = scoped.batches.list_events("b_1").to_a

    assert_equal [Tungo::Models::ChatEventBatch, Tungo::Models::ChatEventDone], events.map(&:class)
    assert_equal "/v1/companies/co_1/batch/b_1/events", server.requests.last.path
    assert_nil server.requests.last.headers["last-event-id"]
  end

  def test_feed_list_events
    item = "id: c_9\nevent: feed\ndata: {\"id\":\"f_1\",\"title\":\"Счёт оплачен\",\"cursor\":\"c_9\"}\n\n"
    server.respond { |_| MockServer.sse([PING, item]) }
    stream = scoped.feed.list_events(last_event_id: "c_8")
    items = stream.to_a

    assert_instance_of Tungo::Stream, stream
    assert_equal [Tungo::Models::FeedItem], items.map(&:class)
    assert_equal "Счёт оплачен", items.first.title
    assert_equal "c_9", stream.last_event_id
    assert_equal "c_8", server.requests.last.headers["last-event-id"]
  end

  def test_feed_error_event_raises_a_stream_error
    failure = "event: error\ndata: {\"error\":\"feed_failed\",\"message\":\"Лента недоступна\"}\n\n"
    server.respond { |_| MockServer.sse([failure]) }
    error = assert_raises(Tungo::StreamError) { scoped.feed.list_events.to_a }

    assert_equal "feed_failed", error.code
    assert_includes error.message, "Лента недоступна"
  end

  def test_each_sse_yields_raw_events_including_pings
    server.respond { |_| MockServer.sse([PING, TEXT]) }
    raw = scoped.chat.create_stream(message: "x").each_sse.to_a

    assert_equal %w[ping text], raw.map(&:event)
    assert_instance_of Tungo::ServerSentEvent, raw.first
    assert_equal({ "type" => "text", "delta" => "Привет" }, raw.last.json)
  end

  def test_error_status_raises_the_typed_error_before_any_event
    server.respond { |_| MockServer.error(402, "payment_required_error", code: "platform_balance_exhausted") }
    error = assert_raises(Tungo::PaymentRequiredError) { scoped.chat.create_stream(message: "x") }

    assert_equal "platform_balance_exhausted", error.code
  end

  def test_opening_a_stream_is_retried_before_the_first_byte
    server.respond do |_, count|
      if count == 1
        MockServer.error(503, "unavailable_error",
                         headers: { "retry-after-ms" => "1" })
      else
        MockServer.sse([DONE])
      end
    end

    assert_equal 1, scoped.chat.create_stream(message: "x").count
    assert_equal 2, server.requests.size
    assert_equal 1, server.requests.map { |request| request.headers["idempotency-key"] }.uniq.size
  end

  def test_non_event_stream_success_is_a_decode_error
    server.respond { |_| MockServer.json({ "answer" => "x" }) }

    assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x") }
  end

  def test_invalid_json_in_an_event_is_a_decode_error
    server.respond { |_| MockServer.sse(["event: text\ndata: {oops\n\n"]) }

    assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x").to_a }
  end

  def test_silent_stream_hits_the_idle_timeout
    server.respond { |_| MockServer.sse([TEXT]).merge(hang: 30) }
    stream = scoped(stream_idle_timeout: 0.3).chat.create_stream(message: "x")
    started = monotonic
    error = assert_raises(Tungo::TimeoutError) { stream.to_a }

    assert_operator monotonic - started, :<, 2
    assert_kind_of Timeout::Error, error.cause
    assert_predicate stream, :closed?
  end

  def test_connection_lost_mid_stream_is_wrapped
    server.respond { |_| MockServer.sse([TEXT]).merge(hang: 30) }
    stream = scoped(stream_idle_timeout: 5).chat.create_stream(message: "x")
    Thread.new do
      sleep(0.3)
      server.close
    end

    assert_raises(Tungo::ConnectionError, Tungo::TimeoutError) { stream.to_a }
  end

  def test_long_streams_are_not_cut_by_the_request_timeout
    server.respond { |_| MockServer.sse([TEXT, TEXT, TEXT, DONE], delay: 0.2) }

    assert_equal 4, scoped(timeout: 0.3).chat.create_stream(message: "x").count
  end

  def test_large_event
    big = "x" * 2_000_000
    server.respond { |_| MockServer.sse(["event: text\ndata: {\"type\":\"text\",\"delta\":\"#{big}\"}\n\n"]) }
    started = monotonic
    events = scoped.chat.create_stream(message: "x").to_a

    assert_equal big.size, events.first.delta.size
    assert_operator monotonic - started, :<, 5
  end
end
