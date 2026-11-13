# frozen_string_literal: true

require_relative "test_helper"
require "pp"

# Configuration, authentication, headers, request building and per-request options.
class ClientTest < TungoTestCase
  def test_default_base_url_is_production
    assert_equal "https://api.tungo.kz", Tungo::DEFAULT_BASE_URL
    assert_equal "https://api.tungo.kz", Tungo::Client.new(api_key: "k").base_url
  end

  def test_environment_fallbacks
    env = { "TUNGO_API_KEY" => "tg_env", "TUNGO_BASE_URL" => "#{server.base_url}/", "TUNGO_COMPANY_ID" => "co_env",
            "TUNGO_WORKSPACE_ID" => "ws_env", "TUNGO_WEBHOOK_SECRET" => "whsec_c2VjcmV0" }
    with_env(env) do
      configured = Tungo::Client.new

      assert_equal server.base_url, configured.base_url
      assert_equal "co_env", configured.company_id
      assert_equal "ws_env", configured.workspace_id
      assert_equal "whsec_c2VjcmV0", configured.webhook_secret
      configured.companies.get
      configured.close
    end

    assert_equal "tg_env", server.requests.last.headers["x-api-key"]
    assert_equal "/v1/companies/co_env", server.requests.last.path
  end

  def test_explicit_options_win_over_the_environment
    with_env("TUNGO_API_KEY" => "tg_env", "TUNGO_COMPANY_ID" => "co_env") do
      client(company_id: "co_explicit").companies.get
    end

    assert_equal "tg_test_key", server.requests.last.headers["x-api-key"]
    assert_equal "/v1/companies/co_explicit", server.requests.last.path
  end

  def test_missing_api_key_raises_before_any_request
    keyless = Tungo::Client.new(base_url: server.base_url)
    error = assert_raises(Tungo::ConfigError) { keyless.companies.list }

    assert_match(/TUNGO_API_KEY/, error.message)
    assert_empty server.requests
  end

  def test_public_and_hook_endpoints_never_get_the_api_key
    keyed = client(default_headers: { "X-App" => "billing" })
    keyed.platform.list_usage_rates
    keyed.automations.post_hook("th_token", { "id" => "evt_1" })

    server.requests.each do |request|
      assert_nil request.headers["x-api-key"], request.path
      assert_nil request.headers["authorization"], request.path
      assert_equal "billing", request.headers["x-app"]
    end
    assert_equal 2, server.requests.size
  end

  def test_public_endpoints_work_without_an_api_key
    keyless = Tungo::Client.new(base_url: server.base_url)

    assert_kind_of Tungo::Model, keyless.platform.list_usage_rates
    keyless.close
  end

  def test_invalid_configuration_is_rejected
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: "k", base_url: "ftp://example.com") }
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: "k", base_url: "not a url") }
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: "k", timeout: 0) }
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: "k", timeout: Float::NAN) }
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: "k", max_retries: -1) }
    assert_raises(Tungo::ConfigError) { Tungo::Client.new(api_key: 42) }
    assert_raises(Tungo::ConfigError) { client.with_options(nope: 1) }
  end

  def test_missing_company_raises
    error = assert_raises(Tungo::ConfigError) { client.chat.list }

    assert_match(/company_id/, error.message)
    assert_empty server.requests
  end

  def test_inspect_never_shows_secrets
    secretive = client(webhook_secret: "whsec_c2VjcmV0X3ZhbHVl")
    [secretive.inspect, secretive.to_s, secretive.pretty_inspect, secretive.chat.inspect,
     secretive.instance_variables.map { |name| secretive.instance_variable_get(name).inspect }.join].each do |text|
      refute_includes text, "tg_test_key"
      refute_includes text, "whsec_c2VjcmV0X3ZhbHVl"
    end
    assert_includes secretive.inspect, "[REDACTED]"
  end

  def test_client_is_frozen_and_with_options_copies
    original = client(company_id: "co_1")
    copy = original.with_options(company_id: "co_2", max_retries: 0)

    assert_predicate original, :frozen?
    assert_equal "co_1", original.company_id
    assert_equal "co_2", copy.company_id
    assert_equal 0, copy.max_retries
    assert_same original.transport, copy.transport
    copy.companies.get

    assert_equal "tg_test_key", server.requests.last.headers["x-api-key"]
  end

  def test_standard_headers
    client.companies.list
    headers = server.requests.last.headers

    assert_equal "application/json", headers["accept"]
    assert_equal "tungo-sdk-ruby/#{Tungo::VERSION}", headers["user-agent"]
    assert_nil headers["content-type"]
    assert_nil headers["idempotency-key"]
  end

  def test_body_keywords_and_nil_versus_omitted
    client(company_id: "co_1").chat.create(message: "Привет", dialog_id: nil)
    request = server.requests.last

    assert_equal "application/json", request.headers["content-type"]
    assert_equal({ "message" => "Привет", "dialog_id" => nil, "stream" => false }, request.json)
  end

  def test_models_times_and_symbols_are_serialised
    attachment = Tungo::Models::ChatAttachment.new(name: "a.pdf")
    client(company_id: "co_1").chat.create(message: "x", attachments: [attachment, { name: "b.pdf" }], mode: :ask)

    assert_equal [{ "name" => "a.pdf" }, { "name" => "b.pdf" }], server.requests.last.json["attachments"]
    assert_equal "ask", server.requests.last.json["mode"]
  end

  def test_query_encoding_on_the_wire
    since = Time.new(2026, 11, 9, 15, 0, 0, "+05:00")
    client(company_id: "co_1").proposals.list(q: "a b&c", limit: 5, date_from: since, status: nil)

    assert_equal "date_from=2026-11-09T15%3A00%3A00%2B05%3A00&limit=5&q=a%20b%26c", server.requests.last.query
  end

  def test_ruby_keywords_work_as_arguments
    client(company_id: "co_1").batches.create_esf_purchases(from: "2026-01-01", to: "2026-02-01")

    assert_equal({ "from" => "2026-01-01", "to" => "2026-02-01" }, server.requests.last.json)
  end

  def test_path_parameters_are_escaped
    client(company_id: "co 1/x").chat.get("a b?c#d")

    assert_equal "/v1/companies/co%201%2Fx/chat/a%20b%3Fc%23d", server.requests.last.target
    assert_raises(Tungo::ValidationError) { client(company_id: "co_1").chat.get("..") }
    assert_raises(Tungo::ValidationError) { client(company_id: "co_1").chat.get("") }
  end

  def test_per_call_scope_overrides
    scoped = client(company_id: "co_default", workspace_id: "ws_default")
    scoped.chat.list(company_id: "co_other")

    assert_equal "/v1/companies/co_other/chat", server.requests.last.path
    scoped.platform.get_account(workspace_id: "ws_other")

    assert_equal "/v1/workspaces/ws_other/platform/account", server.requests.last.path
  end

  def test_request_options_headers_and_idempotency_key
    options = { extra_headers: { "X-Trace" => "abc", "Accept" => "application/json; v=2" }, idempotency_key: "key-1" }
    client(company_id: "co_1").proposals.approve("P-1", request_options: options)
    headers = server.requests.last.headers

    assert_equal "abc", headers["x-trace"]
    assert_equal "application/json; v=2", headers["accept"]
    assert_equal "key-1", headers["idempotency-key"]
  end

  def test_request_options_object_and_validation
    options = Tungo::RequestOptions.new(timeout: 5, max_retries: 0)
    client.companies.list(request_options: options)

    assert_raises(Tungo::ValidationError) { client.companies.list(request_options: { timeout: -1 }) }
    assert_raises(Tungo::ValidationError) { client.companies.list(request_options: { nope: 1 }) }
    assert_raises(Tungo::ValidationError) { client.companies.list(request_options: 5) }
    assert_raises(Tungo::ValidationError) do
      client.companies.list(request_options: { extra_headers: { "X-A" => "a\r\nX-B: b" } })
    end
    assert_equal 1, server.requests.size
  end

  def test_idempotent_posts_get_a_generated_key
    scoped = client(company_id: "co_1")
    scoped.proposals.approve("P-1")
    scoped.proposals.approve("P-1")
    keys = server.requests.map { |request| request.headers["idempotency-key"] }

    assert_match(/\A[0-9a-f-]{36}\z/, keys.first)
    refute_equal keys.first, keys.last
  end

  def test_the_idempotency_key_of_an_approval_body_is_the_header
    # The API prefers the header over the documented body field: a generated header would make a
    # repeat of the same click a new approval.
    scoped = client(company_id: "co_1")
    scoped.proposals.approve("P-1", idempotency_key: " click-7 ")
    scoped.proposals.approve("P-1", idempotency_key: "click-7", request_options: { idempotency_key: "own" })
    scoped.proposals.approve_batch(idempotency_key: "click-8")
    keys = server.requests.map { |request| request.headers["idempotency-key"] }

    assert_equal %w[click-7 own click-8], keys
  end

  def test_api_response_metadata
    server.respond do |_|
      MockServer.json({ "data" => [] }, headers: { "x-ratelimit-limit" => "600", "x-ratelimit-remaining" => "599",
                                                   "x-ratelimit-reset" => "12", "idempotent-replayed" => "true" })
    end
    response = client.companies.list.api_response

    assert_equal 200, response.status
    assert_equal "req_hdr_1", response.request_id
    assert_equal "req_hdr_1", response["X-Request-Id"]
    assert_equal Tungo::RateLimit.new(limit: 600, remaining: 599, reset: 12), response.rate_limit
    assert_predicate response, :idempotent_replayed?
  end

  def test_rate_limit_is_nil_without_headers
    assert_nil client.companies.list.api_response.rate_limit
  end

  def test_empty_result_operations_return_the_response
    server.respond { |_| { status: 204 } }
    result = client(workspace_id: "ws_1").webhooks.delete_endpoint("ep_1")

    assert_instance_of Tungo::APIResponse, result
    assert_equal 204, result.status
  end

  def test_status_selects_the_result_model
    scoped = client(company_id: "co_1")
    server.respond { |_| MockServer.json({ "job_id" => "job_1" }, status: 202) }
    accepted = scoped.proposals.approve_batch(ids: ["P-1"])

    assert_equal 202, accepted.api_response.status
    server.respond { |_| MockServer.json({}, status: 200) }
    done = scoped.proposals.approve_batch(ids: ["P-1"])

    refute_equal accepted.class, done.class
  end

  def test_connections_are_reused
    5.times { client.companies.list }
    shared = client
    5.times { shared.companies.list }

    assert_equal 6, server.connections
    assert_equal 10, server.requests.size
  end

  def test_close_releases_connections_and_the_client_stays_usable
    shared = client
    shared.companies.list
    shared.close
    shared.companies.list

    assert_equal 2, server.connections
  end

  def test_custom_transport
    calls = []
    transport = Object.new
    transport.define_singleton_method(:execute) do |request|
      calls << request
      Tungo::Transport::Response.new(status: 200, headers: { "Content-Type" => "application/json" },
                                     chunks: ['{"data":', "[]}"])
    end
    custom = Tungo::Client.new(api_key: "k", transport: transport)

    assert_empty custom.companies.list.data
    assert_equal "GET", calls.first.verb
    assert_equal "https://api.tungo.kz/v1/companies", calls.first.url.to_s
    assert_equal 60, calls.first.timeout
  end

  def test_thread_safety
    shared = client(company_id: "co_1")
    server.respond { |request| MockServer.json({ "id" => request.path.split("/").last }) }
    results = Array.new(8) do |index|
      Thread.new { Array.new(10) { |turn| shared.chat.get("d#{index}-#{turn}").id } }
    end.map(&:value)

    results.each_with_index do |ids, index|
      assert_equal Array.new(10) { |turn| "d#{index}-#{turn}" }, ids
    end
  end
end
