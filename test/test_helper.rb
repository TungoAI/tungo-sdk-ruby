# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "tungo"
require_relative "support/mock_server"

# The environment of the developer or of CI must not leak into the tests.
ENV.delete_if { |name, _| name.start_with?("TUNGO_") }

# Base class of the test suite: every test gets its own in-process mock server.
class TungoTestCase < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  VECTORS = JSON.parse(File.read(File.join(ROOT, "conformance", "vectors.json"))).freeze

  attr_reader :server

  def setup
    @server = MockServer.new
    @clients = []
  end

  def teardown
    @clients.each(&:close)
    @server.close
  end

  # A client that talks to the mock server.
  def client(**)
    created = Tungo::Client.new(api_key: "tg_test_key", base_url: server.base_url, **)
    @clients << created
    created
  end

  def vectors
    VECTORS
  end

  def with_env(values)
    saved = values.keys.to_h { |name| [name, ENV.fetch(name, nil)] }
    values.each { |name, value| ENV[name] = value }
    yield
  ensure
    saved.each { |name, value| ENV[name] = value }
  end

  # A handler for the mock server that answers every operation with something plausible; used to
  # run the README snippets and the examples.
  def demo_response(request)
    return demo_stream if request.headers["accept"] == "text/event-stream"

    case request.path
    when %r{/chat\z}
      MockServer.json({ "answer" => "Ответ", "dialog_id" => "dlg_1", "turn_no" => 1, "errors" => [],
                        "citations" => [], "proposals" => [], "questions" => [], "pending_question" => nil,
                        "stop_reason" => "end_turn" })
    when %r{/hooks/}
      MockServer.json({ "event_id" => "evt_1", "duplicate" => false, "run_ids" => [] }, status: 202)
    when %r{/automations/} then MockServer.json({ "id" => "run_1", "state" => "done" })
    when %r{/batch} then MockServer.json({ "id" => "b_1", "running" => false })
    else
      MockServer.json({ "id" => "co_1", "name" => "ТОО Ромашка", "next_cursor" => nil,
                        "data" => [{ "id" => "P-1", "name" => "ТОО Ромашка", "title" => "Счёт",
                                     "total" => { "formatted" => "1,00 ₸" } }] },
                      headers: { "x-ratelimit-remaining" => "59" })
    end
  end

  def demo_stream
    MockServer.sse(["event: text\ndata: {\"type\":\"text\",\"delta\":\"Привет\"}\n\n",
                    "event: tool\ndata: {\"type\":\"tool\",\"name\":\"search\",\"status\":\"running\"}\n\n",
                    "event: done\ndata: {\"type\":\"done\",\"stop_reason\":\"end_turn\"}\n\n"],
                   headers: { "X-Dialog-Id" => "dlg_1", "X-Turn-No" => "1" })
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
