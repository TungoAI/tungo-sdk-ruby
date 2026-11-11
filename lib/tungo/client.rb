# frozen_string_literal: true

module Tungo
  # The Tungo Platform API client.
  #
  #   client = Tungo::Client.new(api_key: "tg_...", company_id: "co_...")
  #   result = client.ask("Покажи дебиторку за октябрь")
  #   puts result.answer
  #
  # A client is immutable and safe to share between threads. It keeps a pool of persistent
  # connections; call {#close} to release them when the client is no longer needed.
  class Client
    include Resources::Accessors
    include Helpers

    DEFAULT_TIMEOUT = 60
    DEFAULT_CHAT_TIMEOUT = 600
    DEFAULT_CONNECT_TIMEOUT = 30
    DEFAULT_STREAM_IDLE_TIMEOUT = 120
    DEFAULT_MAX_RETRIES = 2
    USER_AGENT = "tungo-sdk-ruby/#{VERSION}".freeze
    OPTIONS = %i[api_key base_url webhook_secret workspace_id company_id timeout chat_timeout connect_timeout
                 stream_idle_timeout max_retries default_headers transport].freeze
    private_constant :OPTIONS

    # @return [String] the API origin, without a trailing slash
    attr_reader :base_url
    # @return [String, nil] workspace used when a call does not name one
    attr_reader :workspace_id
    # @return [String, nil] company used when a call does not name one
    attr_reader :company_id
    # @return [Numeric] seconds allowed for an ordinary request
    attr_reader :timeout
    # @return [Numeric] seconds allowed for a non-streaming chat turn
    attr_reader :chat_timeout
    # @return [Numeric] seconds allowed to establish a connection
    attr_reader :connect_timeout
    # @return [Numeric] seconds a stream may stay silent
    attr_reader :stream_idle_timeout
    # @return [Integer] how many times a failed request is repeated
    attr_reader :max_retries
    # @return [Hash{String=>String}] headers sent with every request
    attr_reader :default_headers
    # @return [#execute] the HTTP transport
    attr_reader :transport

    # @param api_key [String, nil] API key; defaults to the +TUNGO_API_KEY+ environment variable
    # @param base_url [String, nil] API origin; defaults to +TUNGO_BASE_URL+, then to {DEFAULT_BASE_URL}
    # @param webhook_secret [String, nil] signing secret used by {#verify_webhook}; defaults to
    #   +TUNGO_WEBHOOK_SECRET+
    # @param workspace_id [String, nil] default workspace; defaults to +TUNGO_WORKSPACE_ID+
    # @param company_id [String, nil] default company; defaults to +TUNGO_COMPANY_ID+
    # @param timeout [Numeric] seconds for a whole ordinary request, including reading the body
    # @param chat_timeout [Numeric] seconds for a whole non-streaming chat turn
    # @param connect_timeout [Numeric] seconds to establish a connection
    # @param stream_idle_timeout [Numeric] seconds a stream may stay silent
    # @param max_retries [Integer] how many times a failed request is repeated when that is safe
    # @param default_headers [Hash{String=>String}] headers added to every request
    # @param transport [#execute, nil] HTTP transport; a {Tungo::Transport::NetHTTP} by default. A transport of
    #   your own must never follow a redirect: the request headers hold the API key (the built-in one never does)
    # @raise [Tungo::ConfigError] when an option is invalid
    def initialize(api_key: nil, base_url: nil, webhook_secret: nil, workspace_id: nil, company_id: nil,
                   timeout: DEFAULT_TIMEOUT, chat_timeout: DEFAULT_CHAT_TIMEOUT,
                   connect_timeout: DEFAULT_CONNECT_TIMEOUT, stream_idle_timeout: DEFAULT_STREAM_IDLE_TIMEOUT,
                   max_retries: DEFAULT_MAX_RETRIES, default_headers: {}, transport: nil)
      @api_key = secret(api_key, "TUNGO_API_KEY", header: true)
      @webhook_secret = secret(webhook_secret, "TUNGO_WEBHOOK_SECRET")
      @base_url = check_base_url(setting(base_url, "TUNGO_BASE_URL") || DEFAULT_BASE_URL)
      @workspace_id = setting(workspace_id, "TUNGO_WORKSPACE_ID")
      @company_id = setting(company_id, "TUNGO_COMPANY_ID")
      @timeout = seconds(:timeout, timeout)
      @chat_timeout = seconds(:chat_timeout, chat_timeout)
      @connect_timeout = seconds(:connect_timeout, connect_timeout)
      @stream_idle_timeout = seconds(:stream_idle_timeout, stream_idle_timeout)
      @max_retries = check_retries(max_retries)
      @default_headers = Internal::Util.normalize_headers(default_headers).freeze
      @transport = transport || Transport::NetHTTP.new
      build_resources
      freeze
    end

    # @return [Tungo::Client] a client with some options replaced; it shares the connection pool
    def with_options(**overrides)
      unknown = overrides.keys - OPTIONS
      raise ConfigError, "unknown client option(s): #{unknown.join(", ")}" unless unknown.empty?

      current = {
        api_key: @api_key&.reveal, base_url: @base_url, webhook_secret: @webhook_secret&.reveal,
        workspace_id: @workspace_id, company_id: @company_id, timeout: @timeout, chat_timeout: @chat_timeout,
        connect_timeout: @connect_timeout, stream_idle_timeout: @stream_idle_timeout, max_retries: @max_retries,
        default_headers: @default_headers, transport: @transport
      }
      self.class.new(**current, **overrides)
    end

    # Closes the idle connections of the pool. The client stays usable: new connections are
    # opened on demand.
    def close
      @transport.close if @transport.respond_to?(:close)
      nil
    end

    # The API key and the webhook secret are never shown.
    def inspect
      "#<#{self.class.name} base_url=#{@base_url.inspect} api_key=#{@api_key ? "[REDACTED]" : "nil"} " \
        "workspace_id=#{@workspace_id.inspect} company_id=#{@company_id.inspect} " \
        "timeout=#{@timeout} max_retries=#{@max_retries}>"
    end
    alias to_s inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    # @api private
    # @return [String] the explicit company id, else the client's default
    def resolve_company_id(explicit = nil)
      setting(explicit, nil) || @company_id ||
        raise(ConfigError, "No company: pass company_id: to the call or to Tungo::Client.new, or set TUNGO_COMPANY_ID")
    end

    # @api private
    # @return [String] the explicit workspace id, else the client's default
    def resolve_workspace_id(explicit = nil)
      setting(explicit, nil) || @workspace_id ||
        raise(ConfigError,
              "No workspace: pass workspace_id: to the call or to Tungo::Client.new, or set TUNGO_WORKSPACE_ID")
    end

    # @api private
    # @return [String, nil] the configured webhook secret
    def webhook_secret
      @webhook_secret&.reveal
    end

    # Performs a JSON request and decodes the result. Used by the generated resource methods.
    #
    # @api private
    # @return [Tungo::Model, Tungo::APIResponse, Object] the decoded result; the response
    #   metadata itself when the operation has no response body
    def request(model: nil, models: nil, long_running: false, options: nil, **spec)
      options = RequestOptions.coerce(options)
      call = prepare(options: options, accept: "application/json", **spec)
      timeout = options.timeout || (long_running ? @chat_timeout : @timeout)
      response, body = perform(call, options, timeout: timeout, streaming: false)
      api_response = APIResponse.new(status: response.status, headers: response.headers)
      type = (models && models[response.status]) || model
      type.nil? ? api_response : decode(type, body, api_response)
    end

    # Performs a list request and wraps the result in a page that can fetch the next one.
    #
    # @api private
    # @return [Tungo::Page]
    def page(query: {}, **spec)
      fetch = lambda do |cursor, seen|
        cursor_query = cursor.nil? ? query : query.merge("cursor" => cursor)
        used = cursor_query["cursor"]
        used = nil unless used.is_a?(String)
        Page.new(body: request(query: cursor_query, **spec), cursor: used, fetch: fetch, seen: [*seen, used].compact)
      end
      fetch.call(nil, [])
    end

    # Opens a server-sent event stream. Used by the generated resource methods.
    #
    # @api private
    # @return [Tungo::Stream]
    def stream(event:, stream_class: Stream, last_event_id: nil, options: nil, **spec)
      options = RequestOptions.coerce(options)
      headers = (spec.delete(:headers) || {}).merge("Last-Event-ID" => last_event_id, "Accept-Encoding" => "identity",
                                                    "Cache-Control" => "no-cache")
      call = prepare(options: options, accept: "text/event-stream", headers: headers, **spec)
      response, = perform(call, options, timeout: nil, streaming: true)
      check_event_stream(response)
      stream_class.new(response: response, decode: event_decoder(event))
    end

    private

    Call = Data.define(:verb, :route, :url, :headers, :body, :keyed)
    private_constant :Call

    def setting(value, env)
      value = ENV.fetch(env, nil) if value.nil? && env
      return nil if value.nil?
      raise ConfigError, "#{env || "an id"} must be a String, got #{value.class}" unless value.is_a?(String)

      value.empty? ? nil : value
    end

    def secret(value, env, header: false)
      value = setting(value, env)
      Internal::Util.check_header_secret(value, env) if value && header
      value && Internal::Secret.new(value)
    end

    def seconds(name, value)
      return value if value.is_a?(Numeric) && value.positive? && value.to_f.finite?

      raise ConfigError, "#{name} must be a positive number of seconds, got #{value.inspect}"
    end

    def check_retries(value)
      return value if value.is_a?(Integer) && !value.negative?

      raise ConfigError, "max_retries must be a non-negative Integer, got #{value.inspect}"
    end

    def check_base_url(value)
      url = begin
        URI(value)
      rescue URI::InvalidURIError
        nil
      end
      unless url.is_a?(URI::HTTP) && !url.host.to_s.empty?
        raise ConfigError, "base_url must be an http(s) URL, got #{value.inspect}"
      end

      value.sub(%r{/+\z}, "").freeze
    end

    def api_key!
      return @api_key.reveal if @api_key

      raise ConfigError, "No API key: pass api_key: to Tungo::Client.new or set TUNGO_API_KEY"
    end

    def prepare(method:, path:, options:, accept:, path_params: {}, query: nil, body: OMIT, body_required: true,
                raw_body: OMIT, content_type: OMIT, secret: nil, signature_header: nil, headers: nil, auth: :key,
                idempotency_header: nil, idempotency_default: OMIT)
      url = URI("#{@base_url}#{Internal::Util.build_path(path, path_params)}")
      query_string = query ? Internal::Util.encode_query(query) : ""
      url.query = query_string unless query_string.empty?

      all = { "accept" => accept, "user-agent" => USER_AGENT }.merge(default_headers_for(auth))
      all["x-api-key"] = api_key! if auth == :key
      key = options.idempotency_key || idempotency_key(idempotency_header, idempotency_default)
      all[(idempotency_header || "Idempotency-Key").downcase] = key if key
      payload, type = encode_body(body, body_required, raw_body, content_type)
      all["content-type"] = type if payload && type
      all[signature_header.downcase] = Webhooks.sign_hook_payload(payload || "", secret) if signature_header && secret
      merge_headers(all, headers)
      merge_headers(all, options.extra_headers)
      Call.new(verb: method.to_s.upcase, route: path, url: url, headers: all, body: payload, keyed: !key.nil?)
    end

    # An operation that is not authenticated with the API key (an incoming hook, a public
    # endpoint) gets no credential from the client-wide headers. A header given for the call
    # itself (+extra_headers+) is always sent.
    def default_headers_for(auth)
      auth == :key ? @default_headers : @default_headers.except(*Transport::CREDENTIAL_HEADERS)
    end

    def idempotency_key(header, default)
      return nil if header.nil?

      default.is_a?(String) && !default.empty? ? default : SecureRandom.uuid
    end

    def encode_body(body, body_required, raw_body, content_type)
      type = OMIT.equal?(content_type) ? nil : content_type
      body = body.reject { |_, value| OMIT.equal?(value) } if body.is_a?(Hash)
      body = OMIT if !body_required && body.respond_to?(:empty?) && body.empty?
      unless OMIT.equal?(body)
        return [Internal::Util.generate_json(Internal::Type.wire(body)),
                type || "application/json"]
      end

      case raw_body
      when OMIT then [nil, nil]
      when nil then ["".b, type]
      when String then [raw_body.b, type || "application/octet-stream"]
      else [Internal::Util.generate_json(Internal::Type.wire(raw_body)), type || "application/json"]
      end
    end

    def merge_headers(all, extra)
      (extra || {}).each do |name, value|
        next if value.nil? || OMIT.equal?(value)

        text = Internal::Util.scalar_text(value)
        raise ValidationError, "the #{name} header must not contain line breaks" if text.match?(/[\r\n]/)

        all[name.to_s.downcase] = text
      end
    end

    # Sends the request, repeating it when the retry policy allows. Returns [response, body];
    # for a successful streaming call the body is left unread.
    def perform(call, options, timeout:, streaming:)
      max_retries = options.max_retries || @max_retries
      attempt = 0
      loop do
        outcome = attempt_once(call, options, timeout: timeout, streaming: streaming)
        return outcome unless outcome.is_a?(Exception)

        delay = retry_delay(call, outcome, attempt, max_retries)
        raise outcome if delay.nil?

        sleep(delay)
        attempt += 1
      end
    end

    # Returns [response, body] on success, or the error that ended the attempt.
    def attempt_once(call, options, timeout:, streaming:)
      response = @transport.execute(transport_request(call, options, timeout))
      success = (200..299).cover?(response.status)
      return [response, nil] if success && streaming

      body = begin
        response.read
      ensure
        response.close
      end
      return [response, body] if success

      APIError.from_response(status: response.status, headers: response.headers, body: body)
    rescue TimeoutError, ConnectionError => e
      e
    end

    # Seconds to wait before repeating the request, or nil when it must not be repeated.
    def retry_delay(call, error, attempt, max_retries)
      cause = case error
              when APIError then error.status
              when TimeoutError then :timeout
              else :connection_error
              end
      return nil unless attempt < max_retries && Internal::Util.retryable?(call.verb, call.keyed, cause)

      requested = error.is_a?(APIError) ? error.retry_after : nil
      # Zero, a negative number or a date in the past is no instruction to hammer the API at once.
      return Internal::Util.backoff_delay(attempt) if requested.nil? || !requested.positive?

      requested > Internal::Util::MAX_RETRY_AFTER_SECONDS ? nil : requested
    end

    def transport_request(call, options, timeout)
      connect = options.connect_timeout || @connect_timeout
      idle = timeout || options.idle_timeout || @stream_idle_timeout
      Transport::Request.new(verb: call.verb, url: call.url, headers: call.headers, body: call.body,
                             timeout: timeout, connect_timeout: connect, idle_timeout: idle, route: call.route)
    end

    def decode(type, body, api_response)
      data = parse_json(body, api_response)
      unless data.is_a?(Hash)
        raise DecodeError.new("Expected a JSON object in the response, got #{data.class}", api_response: api_response,
                                                                                           body: body)
      end

      value = Internal::Type.coerce(type, data)
      problem = Internal::Type.mismatch(value, data)
      if problem
        raise DecodeError.new("The API returned status #{api_response.status} with a body that does not match " \
                              "the contract: #{problem}. The request itself was accepted: do not repeat a write " \
                              "because of this error", api_response: api_response, body: body)
      end

      value.is_a?(Model) ? value.with_api_response(api_response) : value
    end

    def parse_json(body, api_response)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      if text.strip.empty?
        raise DecodeError.new("The API returned status #{api_response.status} with an empty body",
                              api_response: api_response, body: body)
      end

      Internal::Util.parse_json(text)
    rescue JSON::ParserError, EncodingError, ArgumentError => e
      raise DecodeError.new("The API returned status #{api_response.status} with a body that is not valid JSON " \
                            "(#{e.class})", api_response: api_response, body: body)
    end

    def check_event_stream(response)
      type = response.headers["content-type"].to_s
      return if type.split(";").first.to_s.strip.casecmp?("text/event-stream")

      body = begin
        response.read
      ensure
        response.close
      end
      raise DecodeError.new("The API answered status #{response.status} to a stream request with " \
                            "#{type.empty? ? "no Content-Type" : "the Content-Type #{type}"} instead of " \
                            "text/event-stream. The request itself was accepted: do not repeat a write " \
                            "because of this error",
                            api_response: APIResponse.new(status: response.status, headers: response.headers),
                            body: body)
    end

    # Builds the function that turns a server-sent event into a typed event.
    def event_decoder(type)
      union = !Models.const_get(type).is_a?(Class)
      lambda do |sse|
        next Stream::SKIP if sse.event == "ping" || sse.data.empty?

        data = sse.json
        raise_stream_error(data) if sse.event == "error" && !union
        unless data.is_a?(Hash)
          raise DecodeError.new("The #{sse.event.inspect} event is not a JSON object",
                                body: sse.data)
        end

        value = Internal::Type.coerce(type, data)
        problem = Internal::Type.mismatch(value, data)
        if problem
          raise DecodeError.new("The #{sse.event.inspect} event does not match the contract: #{problem}",
                                body: sse.data)
        end

        value
      end
    end

    def raise_stream_error(data)
      data = {} unless data.is_a?(Hash)
      code = data["error"].is_a?(String) ? data["error"] : nil
      message = data["message"].is_a?(String) ? data["message"] : "The stream reported an error"
      raise StreamError.new("#{message}#{" (code #{code})" if code}", code: code, data: data)
    end
  end
end
