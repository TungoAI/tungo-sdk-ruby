# frozen_string_literal: true

require_relative "test_helper"
require "pp"

# Behaviour that keeps a caller out of trouble when something around the SDK goes wrong: cut
# streams, wrong content types, odd Retry-After values, looping cursors, threads, bodies of the
# wrong shape, mistyped keys and credentials that must not leak.
class HardeningTest < TungoTestCase
  TEXT = "id: 1\nevent: text\ndata: {\"type\":\"text\",\"delta\":\"Привет\"}\n\n"
  DONE = "id: 2\nevent: done\ndata: {\"type\":\"done\",\"stop_reason\":\"end_turn\"}\n\n"
  FAILURE = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"limit_error\",\"message\":\"Лимит\"}}\n\n"
  COMPANY = { "id" => "co_1", "name" => "ТОО Ромашка", "bin" => nil, "permissions" => ["chat"],
              "status" => "active", "created_at" => "2026-01-02T03:04:05Z" }.freeze

  def scoped(**)
    client(company_id: "co_1", **)
  end

  # --- a stream that ends without "done" ---------------------------------------------------

  def test_a_stream_cut_before_done_is_not_a_finished_turn
    server.respond { |_| MockServer.sse([TEXT, TEXT]) }
    error = assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x").accumulate }

    assert_match(/ended before completion/, error.message)
    assert_equal 200, error.api_response.status
    assert_equal "ПриветПривет", error.body
    assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x").each_text { |_| nil } }
    assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x").accumulate(raise_on_error: false) }
  end

  def test_raw_iteration_of_a_cut_stream_simply_ends
    server.respond { |_| MockServer.sse([TEXT, TEXT]) }

    assert_equal 2, scoped.chat.create_stream(message: "x").count
  end

  def test_a_turn_that_ends_with_an_error_event_is_reported_as_that_error
    server.respond { |_| MockServer.sse([TEXT, FAILURE]) }

    assert_raises(Tungo::LimitError) { scoped.chat.create_stream(message: "x").accumulate }
    turn = scoped.chat.create_stream(message: "x").accumulate(raise_on_error: false)

    assert_instance_of Tungo::Models::ChatEventError, turn.error
    assert_nil turn.stop_reason
  end

  # --- a success answer that is not an event stream ----------------------------------------

  def test_a_stream_answer_without_a_content_type_is_a_decode_error
    server.respond { |_| { status: 200, headers: {}, chunks: [TEXT, DONE] } }
    error = assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x") }

    assert_match(%r{no Content-Type instead of text/event-stream}, error.message)
    assert_equal 200, error.api_response.status
    assert_includes error.body.dup.force_encoding(Encoding::UTF_8), "Привет"
  end

  def test_a_stream_answer_of_another_type_is_a_decode_error
    server.respond { |_| { status: 200, headers: { "content-type" => "text/event-streamish" }, chunks: [DONE] } }

    assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x") }
    server.respond { |_| MockServer.json({ "answer" => "x" }) }
    error = assert_raises(Tungo::DecodeError) { scoped.feed.list_events }

    assert_match(%r{application/json instead of text/event-stream}, error.message)
  end

  def test_an_event_stream_with_parameters_is_accepted
    server.respond do |_|
      { status: 200, headers: { "content-type" => "Text/Event-Stream; charset=utf-8" }, chunks: [TEXT, DONE] }
    end

    assert_equal "Привет", scoped.chat.create_stream(message: "x").accumulate.text
  end

  # --- Retry-After that asks for no wait ---------------------------------------------------

  def test_a_retry_after_of_zero_or_in_the_past_uses_the_normal_backoff
    [{ "retry-after" => "0" }, { "retry-after-ms" => "0" }, { "retry-after" => "Wed, 21 Oct 2015 07:28:00 GMT" }]
      .each do |headers|
      fresh = MockServer.new
      fresh.respond do |_, count|
        count == 1 ? MockServer.error(503, "unavailable_error", headers: headers) : MockServer.json({ "data" => [] })
      end
      started = monotonic
      Tungo::Client.new(api_key: "k", base_url: fresh.base_url).companies.list
      waited = monotonic - started
      fresh.close

      # The first back-off is 0.5 s with a jitter of 0.75..1.
      assert_operator waited, :>=, 0.3, "#{headers} must not cause an immediate retry"
      assert_operator waited, :<, 3
    end
  end

  def test_a_positive_retry_after_is_still_honoured
    server.respond do |_, count|
      if count == 1
        MockServer.error(503, "unavailable_error", headers: { "retry-after-ms" => "20" })
      else
        MockServer.json({ "data" => [] })
      end
    end
    started = monotonic
    client.companies.list

    assert_operator monotonic - started, :<, 0.3
  end

  # --- cursors that loop -------------------------------------------------------------------

  def test_a_cursor_cycle_longer_than_one_page_is_stopped
    following = { nil => "A", "A" => "B", "B" => "A" }
    server.respond do |request|
      cursor = request.query.to_s[/cursor=([^&]+)/, 1]
      MockServer.json({ "data" => [{ "id" => "P-#{cursor}" }], "next_cursor" => following.fetch(cursor) })
    end
    error = assert_raises(Tungo::PaginationError) { scoped.proposals.list_all.take(50) }

    assert_match(/"A" twice/, error.message)
    assert_equal [nil, "cursor=A", "cursor=B"], server.requests.map(&:query)
  end

  def test_the_cursor_a_walk_started_from_is_remembered_too
    server.respond do |request|
      cursor = request.query.to_s[/cursor=([^&]+)/, 1]
      MockServer.json({ "data" => [], "next_cursor" => cursor == "S" ? "T" : "S" })
    end
    page = scoped.proposals.list(cursor: "S").next_page

    assert_equal "S", page.next_cursor
    assert_raises(Tungo::PaginationError) { page.next_page }
    assert_equal 2, server.requests.size
  end

  # --- threads -----------------------------------------------------------------------------

  def test_a_stream_can_be_read_on_another_thread
    server.respond { |_| MockServer.sse([TEXT, TEXT, DONE], delay: 0.05) }
    stream = scoped.chat.create_stream(message: "x")
    turn = Thread.new { stream.accumulate }.value

    assert_equal "ПриветПривет", turn.text
    assert_predicate stream, :closed?
  end

  def test_a_stream_can_be_closed_from_another_thread_while_it_is_read
    server.respond { |_| MockServer.sse([TEXT]).merge(hang: 30) }
    stream = scoped(stream_idle_timeout: 20).chat.create_stream(message: "x")
    seen = Queue.new
    reader = Thread.new do
      stream.each { |event| seen << event }
      :ended
    end
    seen.pop
    started = monotonic
    stream.close

    assert_equal :ended, reader.value
    assert_operator monotonic - started, :<, 2
    assert_predicate stream, :closed?
  end

  # A transport that tells when it has closed a connection.
  class WatchedTransport < Tungo::Transport::NetHTTP
    def finished
      @finished ||= Queue.new
    end

    private

    def finish(connection)
      super
      finished << connection
    end
  end

  def test_closing_returns_only_after_the_connection_is_released
    server.respond { |_| MockServer.sse([TEXT] * 500, delay: 0.01) }
    transport = WatchedTransport.new
    stream = Thread.new { scoped(transport: transport).chat.create_stream(message: "x") }.value

    assert_empty transport.finished
    stream.close

    assert_equal 1, transport.finished.size, "the connection must be closed by the time close returns"
    refute_predicate transport.finished.pop, :started?
  end

  def test_requests_from_many_threads_share_the_pool
    server.respond { |_| MockServer.json({ "data" => [] }) }
    shared = client
    results = Array.new(8) do
      Thread.new { Array.new(5) { shared.companies.list.api_response.status } }
    end.map(&:value)

    assert_equal [200], results.flatten.uniq
    assert_operator server.connections, :<=, 8
  end

  # --- bodies of the wrong shape -----------------------------------------------------------

  def test_a_property_of_the_wrong_kind_is_a_decode_error
    { "name" => 42, "permissions" => "chat", "id" => { "x" => 1 }, "status" => ["active"] }.each do |property, value|
      server.respond { |_| MockServer.json(COMPANY.merge(property => value)) }
      error = assert_raises(Tungo::DecodeError, property) { scoped.companies.get }

      assert_match(/the property "#{property}" of Company must be/, error.message)
      assert_match(/do not repeat a write/, error.message)
      assert_equal 200, error.api_response.status
      assert_includes error.body, "created_at"
    end
  end

  def test_the_value_of_a_wrong_property_is_not_quoted
    server.respond { |_| MockServer.json(COMPANY.merge("name" => { "token" => "th_secret_value" })) }
    error = assert_raises(Tungo::DecodeError) { scoped.companies.get }

    refute_includes error.message, "th_secret_value"
  end

  def test_null_missing_unknown_and_new_enum_values_are_accepted
    body = { "id" => "co_1", "name" => nil, "status" => "brand_new_status", "some_new_field" => { "a" => 1 } }
    server.respond { |_| MockServer.json(body) }
    company = scoped.companies.get

    assert_nil company.name
    assert_equal "brand_new_status", company.status
    refute company.key?(:permissions)
    assert_equal({ "a" => 1 }, company[:some_new_field])
  end

  def test_numbers_keep_their_exact_decimal_value
    turn = { "answer" => "x", "dialog_id" => "d", "turn_no" => 3, "errors" => [], "usage" => { "cost" => 0.1 } }
    server.respond { |_| { status: 200, headers: { "content-type" => "application/json" }, body: JSON.generate(turn) } }
    result = scoped.chat.create(message: "x")

    assert_equal 3, result.turn_no
    assert_instance_of BigDecimal, result.usage[:cost]
    server.respond { |_| MockServer.json(turn.merge("turn_no" => "3")) }

    assert_raises(Tungo::DecodeError) { scoped.chat.create(message: "x") }
  end

  def test_an_event_of_the_wrong_shape_is_a_decode_error
    server.respond { |_| MockServer.sse(["event: text\ndata: {\"type\":\"text\",\"delta\":[1,2]}\n\n"]) }
    error = assert_raises(Tungo::DecodeError) { scoped.chat.create_stream(message: "x").to_a }

    assert_match(/the property "delta" of ChatEventText must be a string, got an array/, error.message)
  end

  # --- the API key -------------------------------------------------------------------------

  def test_a_key_with_a_line_break_or_control_character_is_refused_without_being_shown
    ["tg_live_secret\n", "tg_live_secret\r\n", " tg_live_secret", "tg_live\tsecret", "tg_live\u0000secret",
     "tg_live secret", "tg_live_sеcret"].each do |key|
      error = assert_raises(Tungo::ConfigError, key.inspect) { Tungo::Client.new(api_key: key) }

      refute_includes error.message, "secret"
      refute_includes error.message, "tg_live"
      assert_match(/api_key/, error.message)
    end
    with_env("TUNGO_API_KEY" => "tg_live_secret\n") do
      error = assert_raises(Tungo::ConfigError) { Tungo::Client.new }

      refute_includes error.message, "tg_live"
    end
  end

  def test_an_ordinary_key_is_accepted
    assert_instance_of Tungo::Client, Tungo::Client.new(api_key: "tg_live_Abc-123_~.+/=")
  end

  # --- credentials -------------------------------------------------------------------------

  def test_a_transport_request_never_shows_its_credentials
    request = Tungo::Transport::Request.new(
      verb: "POST", url: URI("https://api.example/hooks/th_secret_token?sig=query_secret"),
      headers: { "x-api-key" => "tg_live_secret", "Authorization" => "Bearer bearer_secret", "accept" => "a/b" },
      body: '{"password":"body_secret"}', timeout: 60, connect_timeout: 30, idle_timeout: 60, route: "/hooks/{token}"
    )
    shown = [request.inspect, request.to_s, request.pretty_inspect, [request].inspect, "#{request}!"].join("\n")

    %w[tg_live_secret bearer_secret th_secret_token query_secret body_secret].each do |secret|
      refute_includes shown, secret
    end
    assert_includes shown, "POST /hooks/{token}"
    assert_includes shown, "[REDACTED]"
    assert_includes shown, "a/b"
    assert_equal "tg_live_secret", request.headers["x-api-key"]
  end

  def test_client_wide_credentials_are_not_sent_to_hooks_and_public_endpoints
    headers = { "Authorization" => "Bearer gateway_token", "X-Api-Key" => "other_key", "Cookie" => "session=1",
                "Proxy-Authorization" => "Basic abc", "X-App" => "billing" }
    server.respond do |request|
      request.path.start_with?("/hooks/") ? MockServer.json({ "event_id" => "e" }, status: 202) : MockServer.json({})
    end
    custom = scoped(default_headers: headers)
    custom.send_hook("th_token", { "id" => "evt_1" })
    hook = server.requests.last

    %w[authorization x-api-key cookie proxy-authorization].each { |name| assert_nil hook.headers[name], name }
    assert_equal "billing", hook.headers["x-app"]
    custom.companies.get
    keyed = server.requests.last

    assert_equal "Bearer gateway_token", keyed.headers["authorization"]
    assert_equal "session=1", keyed.headers["cookie"]
    assert_equal "tg_test_key", keyed.headers["x-api-key"]
  end

  def test_a_credential_given_for_one_call_is_sent
    server.respond { |_| MockServer.json({ "event_id" => "e" }, status: 202) }
    scoped.send_hook("th_token", { "id" => "evt_1" },
                     request_options: { extra_headers: { "Authorization" => "Bearer for_this_hook" } })

    assert_equal "Bearer for_this_hook", server.requests.last.headers["authorization"]
  end

  # --- the total timeout -------------------------------------------------------------------

  # A connection that takes its time to open and records the timeouts it is given.
  class SlowConnection
    attr_reader :timeouts
    attr_accessor :open_timeout, :write_timeout

    def initialize(connect_seconds)
      @connect_seconds = connect_seconds
      @timeouts = []
      @started = false
    end

    def read_timeout=(value)
      @timeouts << value
    end

    def started?
      @started
    end

    def start
      sleep(@connect_seconds)
      @started = true
    end

    def request(_message)
      raise Net::ReadTimeout
    end

    def finish
      @started = false
    end
  end

  # A transport whose connections are slow to open.
  class SlowTransport < Tungo::Transport::NetHTTP
    attr_reader :connection

    private

    def connect(_url)
      @connection = SlowConnection.new(0.4)
    end
  end

  def test_percent_encoded_proxy_credentials_reach_net_http_decoded
    transport = Tungo::Transport::NetHTTP.new(proxy: "http://us%3Aer:p%40ss+1@proxy.example:3128")
    connection = transport.send(:connect, URI("https://api.tungo.kz/v1/x"))

    assert_equal "proxy.example", connection.proxy_address
    assert_equal 3128, connection.proxy_port
    assert_equal "us:er", connection.proxy_user
    assert_equal "p@ss+1", connection.proxy_pass, "a plus sign of the userinfo is not a space"
  end

  def test_a_proxy_without_credentials_has_none
    connection = Tungo::Transport::NetHTTP.new(proxy: "http://proxy.example:3128").send(:connect, URI("https://api.tungo.kz/v1/x"))

    assert_nil connection.proxy_user
    assert_nil connection.proxy_pass
  end

  def test_the_time_spent_connecting_is_taken_off_the_total_timeout
    transport = SlowTransport.new
    request = Tungo::Transport::Request.new(verb: "GET", url: URI("http://127.0.0.1:1/v1/x"), headers: {}, body: nil,
                                            timeout: 1.0, connect_timeout: 5, idle_timeout: 1.0, route: "/v1/x")

    assert_raises(Tungo::TimeoutError) { transport.execute(request) }
    before, after = transport.connection.timeouts

    assert_in_delta 1.0, before, 0.1
    assert_operator after, :<=, 0.65, "what is left of 1 s after 0.4 s of connecting"
    assert_operator after, :>, 0.2
  end

  # --- what both the PHP and the Ruby SDK promise ------------------------------------------

  def test_the_wait_helpers_wait_ten_minutes_by_default
    %i[wait_for_run wait_for_batch run_scenario_and_wait].each do |name|
      source = File.read(File.join(ROOT, "lib", "tungo", "helpers.rb"))

      assert_match(/def #{name}\(.*?timeout: 600\b/m, source, name.to_s)
    end
    assert_operator Tungo::WaitTimeoutError, :<, Tungo::TimeoutError
  end

  def test_a_hook_without_an_event_id_gets_a_random_idempotency_key
    server.respond { |_| MockServer.json({ "event_id" => "e" }, status: 202) }
    client.send_hook("th_token", { "id" => 1 })
    client.send_hook("th_token", { "id" => 1 })
    client.send_hook("th_token", { "id" => 1 }, event_id: "evt_7")
    keys = server.requests.map { |request| request.headers["idempotency-key"] }

    assert_match(/\A[0-9a-f-]{36}\z/, keys[0])
    refute_equal keys[0], keys[1]
    assert_equal "evt_7", keys[2]
  end
end
