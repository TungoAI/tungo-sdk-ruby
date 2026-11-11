# frozen_string_literal: true

require_relative "test_helper"
require "stringio"
require "tmpdir"

# Runs every Ruby snippet of the README against the mock server, so the documentation cannot
# drift away from the code.
class ReadmeTest < TungoTestCase
  README = File.read(File.join(ROOT, "README.md"))
  SNIPPETS = README.scan(/^```ruby\n(.*?)^```$/m).flatten.freeze
  SECRET = "whsec_MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY="
  WEBHOOK = '{"id":"evt_1","type":"proposal.written","created_at":"2026-11-09T15:00:00.000Z",' \
            '"workspace_id":"ws_1","company_id":"co_1","data":{"proposal_id":"P-000042","kind":"Счёт"}}'

  # What the snippets print when the API answers with the demo responses of the test helper: the
  # snippet that contains the key must print exactly the value.
  OUTPUT = {
    "client.ask(" => "Ответ\ndialog dlg_1\nТОО Ромашка\n",
    "dialog.api_response.request_id" => "req_hdr_1\n59\n",
    "page.next_page if page.next_page?" => "Счёт\nP-1 1,00 ₸\n1\n",
    "stream.each_text" => "Привет\ndialog dlg_1, turn 1, stop reason end_turn\nПривет[search]\n",
    "client.verify_webhook(" => "Proposal P-000042 was written\nevt_1\n",
    "client.run_scenario_and_wait(" => "done\nfalse\n",
    "rescue Tungo::LimitError" => "",
    "Tungo::Money.to_tiyn(" => ""
  }.freeze

  # What a Rack request looks like to the webhook snippet.
  RackRequest = Struct.new(:body, :env)

  def test_the_readme_has_snippets_for_every_topic
    assert_operator SNIPPETS.size, :>=, 10
    %w[client.ask create_stream list_all verify_webhook send_hook request_options Tungo::Money
       run_scenario_and_wait upload_bank_statement Tungo::LimitError].each do |topic|
      assert(SNIPPETS.any? { |snippet| snippet.include?(topic) }, "no snippet shows #{topic}")
    end
  end

  def test_every_snippet_runs
    server.respond { |request| demo_response(request) }
    env = { "TUNGO_API_KEY" => "tg_test_key", "TUNGO_BASE_URL" => server.base_url, "TUNGO_COMPANY_ID" => "co_1",
            "TUNGO_WORKSPACE_ID" => "ws_1", "TUNGO_WEBHOOK_SECRET" => SECRET }
    Dir.mktmpdir do |dir|
      File.binwrite(File.join(dir, "kl_to_1c.txt"), "1CClientBankExchange\r\n")
      Dir.chdir(dir) do
        with_env(env) { SNIPPETS.each_with_index { |snippet, index| check_snippet(snippet, index) } }
      end
    end

    assert_operator server.requests.size, :>=, 15
    assert(server.requests.all? { |request| request.headers["host"].start_with?("127.0.0.1") })
  end

  def test_the_output_of_every_printing_snippet_is_checked
    OUTPUT.each_key do |marker|
      assert_equal 1, SNIPPETS.count { |snippet| snippet.include?(marker) }, "no single snippet has #{marker}"
    end
    SNIPPETS.each do |snippet|
      next unless snippet.match?(/^\s*(puts|print|warn)\b|\{ \|\w+\| (puts|print) /)

      assert(OUTPUT.keys.any? { |marker| snippet.include?(marker) },
             "the output of a snippet is not checked:\n#{snippet}")
    end
  end

  def test_install_instructions_name_the_gem
    assert_includes README, "gem install tungo-sdk"
    assert_includes README, "bundle add tungo-sdk"
    assert_includes README, 'require "tungo"'
  end

  def test_documented_operations_exist
    documented = README.scan(/^\| `client\.(\w+)` \| .*? \| (.*) \|$/)

    assert_equal 13, documented.size
    documented.each do |resource, methods|
      target = Tungo::Client.new(api_key: "k").public_send(resource)
      methods.scan(/[a-z_]+/).each { |name| assert_respond_to target, name, "client.#{resource}.#{name}" }
    end
  end

  private

  def check_snippet(snippet, index)
    printed = run_snippet(snippet, index)
    marker = OUTPUT.keys.find { |key| snippet.include?(key) }
    return if marker.nil?

    assert_equal OUTPUT.fetch(marker), printed, "README snippet #{index + 1} printed something else\n#{snippet}"
  end

  def run_snippet(snippet, index)
    context = SnippetContext.new(Tungo::Client.new, signed_request)
    output = StringIO.new
    original = [$stdout, $stderr]
    $stdout = $stderr = output
    begin
      context.run(snippet, "README.md snippet #{index + 1}")
    rescue StandardError, ScriptError => e
      flunk "README snippet #{index + 1} failed with #{e.class}: #{e.message}\n#{snippet}"
    ensure
      $stdout, $stderr = original
      context.client.close
    end
    output.string
  end

  def signed_request
    timestamp = Time.now.to_i
    key = Base64.strict_decode64(SECRET.delete_prefix("whsec_"))
    signature = Base64.strict_encode64(OpenSSL::HMAC.digest("SHA256", key, "msg_1.#{timestamp}.#{WEBHOOK}"))
    RackRequest.new(StringIO.new(WEBHOOK), { "HTTP_WEBHOOK_ID" => "msg_1", "HTTP_WEBHOOK_TIMESTAMP" => timestamp.to_s,
                                             "HTTP_WEBHOOK_SIGNATURE" => "v1,#{signature}" })
  end

  # The names a snippet may use without defining them: +client+ and, in a web endpoint, +request+.
  class SnippetContext
    attr_reader :client, :request

    def initialize(client, request)
      @client = client
      @request = request
    end

    def run(source, name)
      client = @client
      request = @request
      scope = binding
      scope.local_variable_set(:client, client)
      scope.local_variable_set(:request, request)
      scope.eval(source, name)
    end
  end
end
