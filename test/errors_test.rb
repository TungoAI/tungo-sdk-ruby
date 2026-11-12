# frozen_string_literal: true

require_relative "test_helper"

# Errors, retries and timeouts.
class ErrorsTest < TungoTestCase
  def fast(**)
    client(max_retries: 0, **)
  end

  def test_hierarchy
    [Tungo::ConfigError, Tungo::ValidationError, Tungo::ConnectionError, Tungo::TimeoutError, Tungo::DecodeError,
     Tungo::PaginationError, Tungo::StreamError, Tungo::WebhookVerificationError, Tungo::APIError].each do |klass|
      assert_operator klass, :<, Tungo::Error
    end
    assert_operator Tungo::MoneyError, :<, Tungo::ValidationError
    assert_operator Tungo::WaitTimeoutError, :<, Tungo::TimeoutError
    Tungo::APIError::ERROR_CLASSES.each_value { |klass| assert_operator klass, :<, Tungo::APIError }
    assert_equal 10, Tungo::APIError::ERROR_CLASSES.size
  end

  def test_api_error_carries_everything
    fields = [{ "path" => "lines[0].amount", "code" => "required", "message" => "Укажите сумму" }]
    server.respond do |_|
      MockServer.error(400, "invalid_request_error", message: "Проверьте поля", code: "validation",
                                                     extra: { "fields" => fields, "hint" => "см. документацию" })
    end
    error = assert_raises(Tungo::InvalidRequestError) { fast.companies.list }

    assert_equal 400, error.status
    assert_equal "invalid_request_error", error.type
    assert_equal "validation", error.code
    assert_equal "Проверьте поля", error.api_message
    assert_equal "req_body_1", error.request_id
    assert_instance_of Tungo::Models::FieldError, error.fields.first
    assert_equal "lines[0].amount", error.fields.first.path
    assert_equal({ "hint" => "см. документацию" }, error.extra)
    assert_equal "req_hdr_1", error.headers["x-request-id"]
    assert_includes error.message, "Проверьте поля"
    assert_includes error.message, "400"
    assert_includes error.message, "req_body_1"
    assert_predicate error, :envelope?
  end

  def test_error_messages_never_contain_the_api_key
    server.respond { |_| MockServer.error(401, "authentication_error", message: "Ключ не подходит") }
    error = assert_raises(Tungo::AuthenticationError) { fast.companies.list }

    refute_includes error.message, "tg_test_key"
    refute_includes error.inspect, "tg_test_key"
  end

  def test_non_json_error_body
    server.respond { |_| { status: 502, headers: { "content-type" => "text/html" }, body: "<html>Bad Gateway</html>" } }
    error = assert_raises(Tungo::UnavailableError) { fast.companies.list }

    assert_equal "unavailable_error", error.type
    assert_equal "<html>Bad Gateway</html>", error.body
    refute_predicate error, :envelope?
  end

  def test_success_with_invalid_json_is_a_decode_error
    server.respond { |_| { status: 200, headers: { "content-type" => "application/json" }, body: "{not json" } }
    error = assert_raises(Tungo::DecodeError) { fast.companies.list }

    assert_equal 200, error.api_response.status
    assert_equal "{not json", error.body
  end

  def test_success_with_empty_or_non_object_body_is_a_decode_error
    server.respond { |_| { status: 200, body: "" } }

    assert_raises(Tungo::DecodeError) { fast.companies.list }
    server.respond { |_| { status: 200, body: "[1,2]" } }

    assert_raises(Tungo::DecodeError) { fast.companies.list }
  end

  def test_connection_refused_is_wrapped_with_its_cause
    dead = TCPServer.new("127.0.0.1", 0)
    port = dead.addr[1]
    dead.close
    refused = Tungo::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 0)
    error = assert_raises(Tungo::ConnectionError) { refused.companies.list }

    assert_kind_of SystemCallError, error.cause
    assert_includes error.message, "GET /v1/companies"
  end

  def test_a_redirect_is_never_followed
    other = MockServer.new
    location = "#{other.base_url}/v1/elsewhere"
    server.respond { |_| { status: 302, headers: { "location" => location }, body: "" } }
    plain = client(company_id: "co_1", max_retries: 0)
    error = assert_raises(Tungo::APIError) { plain.companies.list }

    assert_equal 302, error.status
    streamed = assert_raises(Tungo::APIError) { plain.chat.create_stream(message: "x").to_a }

    assert_equal 302, streamed.status
    assert_equal 2, server.requests.size
    assert_empty other.requests, "the API key must not reach another host"
  ensure
    other&.close
  end

  def test_the_hook_token_never_appears_in_an_error
    dead = TCPServer.new("127.0.0.1", 0)
    port = dead.addr[1]
    dead.close
    token = "SECRET_HOOK_TOKEN_123"
    refused = Tungo::Client.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", max_retries: 0)
    error = assert_raises(Tungo::ConnectionError) { refused.send_hook(token, "{}") }

    assert_includes error.message, "POST /hooks/{token}"
    text = [error, error.cause].compact.map { |e| "#{e.message} #{e.inspect} #{e.full_message}" }.join(" ")

    refute_includes text, token
  end

  def test_dropped_connection_is_wrapped
    server.respond { |_| { drop: true } }
    error = assert_raises(Tungo::ConnectionError) { fast.companies.list }

    refute_nil error.cause
  end

  def test_truncated_body_is_wrapped
    server.respond { |_| MockServer.json({ "data" => [] }).merge(truncate: true) }

    assert_raises(Tungo::ConnectionError) { fast.companies.list }
  end

  def test_timeout_is_wrapped_and_bounded
    server.respond { |_| MockServer.json({}).merge(sleep: 3) }
    started = monotonic
    error = assert_raises(Tungo::TimeoutError) { fast(timeout: 0.3).companies.list }

    assert_operator monotonic - started, :<, 2
    assert_kind_of Net::ReadTimeout, error.cause
  end

  def test_per_request_timeout
    server.respond { |_| MockServer.json({}).merge(sleep: 3) }
    started = monotonic

    assert_raises(Tungo::TimeoutError) { fast.companies.list(request_options: { timeout: 0.3 }) }
    assert_operator monotonic - started, :<, 2
  end

  def test_total_timeout_covers_a_slowly_trickling_body
    server.respond do |_|
      { status: 200, headers: { "content-type" => "application/json" }, chunks: [" "] * 40, delay: 0.1 }
    end
    started = monotonic

    assert_raises(Tungo::TimeoutError) { fast(timeout: 0.5).companies.list }
    assert_operator monotonic - started, :<, 2
  end

  def test_chat_turns_use_the_long_timeout
    calls = []
    transport = Object.new
    transport.define_singleton_method(:execute) do |request|
      calls << request
      Tungo::Transport::Response.new(status: 200, headers: {}, chunks: ["{}"])
    end
    custom = Tungo::Client.new(api_key: "k", company_id: "co_1", transport: transport, chat_timeout: 321)
    custom.chat.create(message: "x")
    custom.chat.create(message: "x", request_options: { timeout: 7 })
    custom.chat.list

    assert_equal [321, 7, 60], calls.map(&:timeout)
  end

  def test_get_is_retried_on_retryable_statuses
    server.respond do |_, count|
      if count < 3
        MockServer.error(503, "unavailable_error",
                         headers: { "retry-after-ms" => "10" })
      else
        MockServer.json({})
      end
    end
    client.companies.list

    assert_equal 3, server.requests.size
  end

  def test_retries_stop_at_max_retries
    server.respond { |_| MockServer.error(500, "api_error", headers: { "retry-after-ms" => "1" }) }

    assert_raises(Tungo::ServerError) { client(max_retries: 1).companies.list }
    assert_equal 2, server.requests.size
    assert_raises(Tungo::ServerError) { client.companies.list(request_options: { max_retries: 0 }) }
    assert_equal 3, server.requests.size
  end

  def test_non_retryable_status_is_not_retried
    server.respond { |_| MockServer.error(404, "not_found_error") }

    assert_raises(Tungo::NotFoundError) { client.companies.list }
    assert_equal 1, server.requests.size
  end

  def test_post_without_idempotency_key_is_not_retried
    server.respond { |_| MockServer.error(503, "unavailable_error", headers: { "retry-after-ms" => "1" }) }

    assert_raises(Tungo::UnavailableError) { client(company_id: "co_1").chat.count_tokens(message: "x") }
    assert_equal 1, server.requests.size
  end

  def test_a_caller_key_does_not_make_an_undeclared_post_retryable
    # count-tokens declares no Idempotency-Key: the API ignores a key there, so it is not sent
    # and a lost answer is not followed by a second, billed request.
    server.respond { |_| MockServer.error(503, "unavailable_error", headers: { "retry-after-ms" => "1" }) }
    options = { idempotency_key: "k-1", extra_headers: { "Idempotency-Key" => "k-2" } }

    assert_raises(Tungo::UnavailableError) do
      client(company_id: "co_1").chat.count_tokens(message: "x", request_options: options)
    end
    assert_equal 1, server.requests.size
    assert_nil server.requests.first.headers["idempotency-key"]
  end

  def test_idempotent_post_is_retried_with_the_same_key
    server.respond do |_, count|
      if count == 1
        MockServer.error(503, "unavailable_error",
                         headers: { "retry-after-ms" => "1" })
      else
        MockServer.json({})
      end
    end
    client(company_id: "co_1").proposals.approve("P-1")
    keys = server.requests.map { |request| request.headers["idempotency-key"] }

    assert_equal 2, keys.size
    assert_equal keys.first, keys.last
  end

  def test_connection_errors_are_retried
    server.respond { |_, count| count == 1 ? { drop: true } : MockServer.json({}) }
    client.companies.list

    assert_equal 2, server.requests.size
  end

  def test_retry_after_is_honoured
    server.respond do |_, count|
      count == 1 ? MockServer.error(429, "limit_error", headers: { "Retry-After" => "1" }) : MockServer.json({})
    end
    started = monotonic
    client.companies.list

    assert_operator monotonic - started, :>=, 0.9
  end

  def test_long_retry_after_is_raised_instead_of_slept
    server.respond { |_| MockServer.error(429, "limit_error", headers: { "Retry-After" => "3600" }) }
    started = monotonic
    error = assert_raises(Tungo::LimitError) { client.companies.list }

    assert_in_delta 3600, error.retry_after
    assert_operator monotonic - started, :<, 2
    assert_equal 1, server.requests.size
  end

  def test_rate_limit_headers_on_errors
    headers = { "x-ratelimit-limit" => "60", "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => "30" }
    server.respond { |_| MockServer.error(429, "limit_error", headers: headers) }
    error = assert_raises(Tungo::LimitError) { fast.companies.list }

    assert_equal Tungo::RateLimit.new(limit: 60, remaining: 0, reset: 30), error.rate_limit
  end

  def test_interrupting_a_call_closes_the_connection
    server.respond { |_| MockServer.json({}).merge(sleep: 5) }
    started = monotonic

    assert_raises(Timeout::Error) { Timeout.timeout(0.3) { fast.companies.list } }
    assert_operator monotonic - started, :<, 2
  end
end
