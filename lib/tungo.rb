# frozen_string_literal: true

require 'base64'
require 'json'
require 'net/http'
require 'openssl'
require 'securerandom'
require 'uri'
require_relative 'tungo/models'
require_relative 'tungo/resources'

module Tungo
  class Error < StandardError; end

  class ApiError < Error
    attr_reader :status, :code, :hint, :request_id, :retry_after

    def initialize(status:, code:, message:, hint: nil, request_id: nil, retry_after: nil)
      super(message)
      @status = status
      @code = code
      @hint = hint
      @request_id = request_id
      @retry_after = retry_after
    end
  end

  class ValidationError < ApiError; end
  class AuthError < ApiError; end
  class PaymentRequiredError < ApiError; end
  class PermissionError < ApiError; end
  class NotFoundError < ApiError; end
  class ConflictError < ApiError; end
  class RateLimitError < ApiError; end

  module Money
    module_function

    def to_tiyn(amount)
      (amount.to_f * 100.0).round
    end

    def to_tenge(tiyn)
      tiyn.to_i / 100.0
    end

    def format_tiyn(tiyn, currency = 'KZT')
      symbol = case currency.to_s.strip.upcase
               when '', 'KZT' then '₸'
               when 'USD' then '$'
               when 'EUR' then '€'
               when 'RUB' then '₽'
               else currency.to_s.strip.upcase
               end
      neg = tiyn.to_i.negative?
      abs_val = tiyn.to_i.abs
      whole = (abs_val / 100).to_s.reverse.gsub(/(\d{3})(?=\d)/, '\\1 ').reverse
      frac = format('%02d', abs_val % 100)
      "#{neg ? '-' : ''}#{whole},#{frac} #{symbol}"
    end

    # Проверяет контрольный разряд 12-значного БИН/ИИН Республики Казахстан (модуль 11, 2 прохода).
    def valid_bin_iin?(value)
      s = value.to_s.strip
      return false unless s.match?(/\A\d{12}\z/)

      digits = s.chars.map(&:to_i)
      w1 = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
      sum1 = (0...11).sum { |i| digits[i] * w1[i] }
      rem = sum1 % 11
      if rem == 10
        w2 = [3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 2]
        sum2 = (0...11).sum { |i| digits[i] * w2[i] }
        rem = sum2 % 11
      end
      rem < 10 && rem == digits[11]
    end
  end

  module Webhooks
    module_function

    def sign_hook_payload(raw_body, secret)
      'sha256=' + OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
    end

    def verify_hook_signature(raw_body, signature_header, secret)
      return false if signature_header.nil? || signature_header.empty? || secret.nil? || secret.empty?

      expected = sign_hook_payload(raw_body, secret)
      candidate = signature_header.strip
      candidate = "sha256=#{candidate}" unless candidate.start_with?('sha256=')
      return false unless expected.bytesize == candidate.bytesize

      OpenSSL.fixed_length_secure_compare(expected, candidate)
    end

    def verify_webhook(raw_body, headers, secret, now_unix: nil, tolerance_sec: 300)
      norm = headers.transform_keys { |k| k.to_s.downcase }
      msg_id = norm['svix-id'] || norm['webhook-id']
      msg_ts = norm['svix-timestamp'] || norm['webhook-timestamp']
      msg_sig = norm['svix-signature'] || norm['webhook-signature']
      raise Error, 'Missing svix headers' if !msg_id || !msg_ts || !msg_sig

      ts = Integer(msg_ts)
      raise Error, 'Webhook timestamp outside tolerance' if now_unix && tolerance_sec.positive? && (now_unix - ts).abs > tolerance_sec

      key_bytes = Base64.strict_decode64(secret.sub(/\Awhsec_/, ''))
      signed = "#{msg_id}.#{msg_ts}.#{raw_body}"
      expected_b64 = Base64.strict_encode64(OpenSSL::HMAC.digest('SHA256', key_bytes, signed))
      matched = msg_sig.split.any? do |part|
        part.start_with?('v1,') &&
          expected_b64.bytesize == part.sub(/\Av1,/, '').bytesize &&
          OpenSSL.fixed_length_secure_compare(expected_b64, part.sub(/\Av1,/, ''))
      end
      raise Error, 'Invalid svix-signature' unless matched

      JSON.parse(raw_body)
    end
  end

  class Client
    attr_reader :workspaces
    attr_reader :companies
    attr_reader :platform
    attr_reader :api_keys
    attr_reader :webhooks
    attr_reader :chat
    attr_reader :proposals
    attr_reader :feed
    attr_reader :batches
    attr_reader :esf
    attr_reader :forms
    attr_reader :onec
    attr_reader :automations

    def initialize(
      api_key: ENV['TUNGO_API_KEY'],
      base_url: ENV.fetch('TUNGO_BASE_URL', 'https://api.tungo.kz'),
      workspace_id: ENV['TUNGO_WORKSPACE_ID'],
      company_id: ENV['TUNGO_COMPANY_ID'],
      max_retries: 3,
      timeout_sec: 30
    )
      @api_key = api_key
      @base_url = base_url.sub(%r{/\z}, '')
      @workspace_id = workspace_id
      @company_id = company_id
      @max_retries = [max_retries.to_i, 0].max
      @timeout_sec = timeout_sec
      @workspaces = Resources::WorkspacesResource.new(self)
      @companies = Resources::CompaniesResource.new(self)
      @platform = Resources::PlatformResource.new(self)
      @api_keys = Resources::ApiKeysResource.new(self)
      @webhooks = Resources::WebhooksResource.new(self)
      @chat = Resources::ChatResource.new(self)
      @proposals = Resources::ProposalsResource.new(self)
      @feed = Resources::FeedResource.new(self)
      @batches = Resources::BatchesResource.new(self)
      @esf = Resources::EsfResource.new(self)
      @forms = Resources::FormsResource.new(self)
      @onec = Resources::OnecResource.new(self)
      @automations = Resources::AutomationsResource.new(self)
    end

    def resolve_company_id(explicit = nil)
      co = explicit && !explicit.empty? ? explicit : @company_id
      raise Error, 'Не указан company_id' if co.nil? || co.empty?

      co
    end

    def resolve_workspace_id(explicit = nil)
      ws = explicit && !explicit.empty? ? explicit : @workspace_id
      raise Error, 'Не указан workspace_id' if ws.nil? || ws.empty?

      ws
    end

    # Быстрый синхронный запрос к ИИ-бухгалтеру (stream = false).
    def ask(prompt, company_id: nil, dialog_id: nil)
      body = { 'message' => prompt, 'stream' => false }
      body['dialog_id'] = dialog_id if dialog_id && !dialog_id.empty?
      params = company_id ? { 'co' => company_id } : {}
      @chat.create(body: body, params: params)
    end

    # Ожидает завершения запуска сценария автоматизации (state in done | error | cancelled | skipped).
    def wait_for_run(run_id, company_id: nil, poll_interval_sec: 1.0, timeout_sec: 120.0)
      params = company_id ? { 'co' => company_id } : {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
      loop do
        run = @automations.get_run(run_id, params: params)
        state = run['state'].to_s
        return run if %w[done error cancelled skipped].include?(state)
        raise Error, "wait_for_run превысил таймаут #{timeout_sec} с для #{run_id}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(poll_interval_sec)
      end
    end

    # Ожидает завершения пакетной задачи (running == false).
    def wait_for_batch(batch_id, company_id: nil, poll_interval_sec: 1.5, timeout_sec: 300.0)
      params = company_id ? { 'co' => company_id } : {}
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_sec
      loop do
        job = @batches.get(batch_id, params: params)
        return job unless job['running']
        raise Error, "wait_for_batch превысил таймаут #{timeout_sec} с для #{batch_id}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep(poll_interval_sec)
      end
    end

    def self.parse_sse(raw)
      raw.to_s.gsub("\r\n", "\n").split("\n\n").filter_map do |frame|
        next if frame.strip.empty?

        ev = 'message'
        data_lines = []
        frame.split("\n").each do |line|
          next if line.empty? || line.start_with?(':')

          if line.start_with?('event:')
            ev = line[6..].strip
          elsif line.start_with?('data:')
            v = line[5..]
            v = v[1..] if v.start_with?(' ')
            data_lines << v
          end
        end
        next if data_lines.empty?

        raw_data = data_lines.join("\n")
        parsed = begin
          JSON.parse(raw_data)
        rescue StandardError
          nil
        end
        { 'event' => ev, 'raw' => raw_data, 'data' => parsed }
      end
    end

    def request(method, path, query: {}, body: nil, auth: 'key', idempotent: false, retry_safe: false)
      uri = build_uri(path, query)
      idemp_key = idempotent ? SecureRandom.uuid : nil
      can_retry = retry_safe || idempotent || %w[GET HEAD OPTIONS].include?(method)
      limit = can_retry ? @max_retries : 0

      (0..limit).each do |attempt|
        resp = execute_http(uri, method, body, auth: auth, idemp_key: idemp_key, accept: 'application/json')
        status = resp.code.to_i
        if status >= 200 && status < 300
          return {} if resp.body.nil? || resp.body.strip.empty?

          return JSON.parse(resp.body)
        end
        if attempt < limit && [429, 502, 503, 504].include?(status)
          sleep(0.3 * (1 << attempt))
          next
        end
        raise build_api_error(status, resp.body, resp['retry-after'])
      end
      {}
    end

    def request_stream(method, path, query: {}, body: nil, auth: 'key')
      uri = build_uri(path, query)
      resp = execute_http(uri, method, body, auth: auth, idemp_key: nil, accept: 'text/event-stream')
      status = resp.code.to_i
      raise build_api_error(status, resp.body, resp['retry-after']) if status < 200 || status >= 300

      events = self.class.parse_sse(resp.body)
      events.each { |ev| yield ev } if block_given?
      events
    end

    private

    def build_uri(path, query)
      uri = URI.parse(@base_url + path)
      unless query.nil? || query.empty?
        uri.query = URI.encode_www_form(query.sort.to_h)
      end
      uri
    end

    def execute_http(uri, method, body, auth:, idemp_key:, accept:)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = @timeout_sec
      http.read_timeout = @timeout_sec

      req_class = case method.upcase
                  when 'GET' then Net::HTTP::Get
                  when 'POST' then Net::HTTP::Post
                  when 'PUT' then Net::HTTP::Put
                  when 'PATCH' then Net::HTTP::Patch
                  when 'DELETE' then Net::HTTP::Delete
                  else Net::HTTP::Post
                  end
      req = req_class.new(uri.request_uri)
      req['Accept'] = accept
      req['User-Agent'] = 'tungo-sdk-ruby/0.1.0'
      req['Authorization'] = "Bearer #{@api_key}" if auth != 'none' && @api_key && !@api_key.empty?
      req['Idempotency-Key'] = idemp_key if idemp_key
      unless body.nil?
        req['Content-Type'] = 'application/json'
        req.body = body.is_a?(String) ? body : JSON.generate(body)
      end
      http.request(req)
    end

    def build_api_error(status, raw_body, retry_after)
      parsed = begin
        JSON.parse(raw_body.to_s)
      rescue StandardError
        {}
      end
      err_obj = parsed.is_a?(Hash) && parsed['error'].is_a?(Hash) ? parsed['error'] : (parsed.is_a?(Hash) ? parsed : {})
      code = err_obj['code'] || 'api_error'
      msg = err_obj['message'] || raw_body.to_s
      hint = err_obj['hint'] || (parsed.is_a?(Hash) ? parsed['hint'] : nil)
      req_id = parsed.is_a?(Hash) ? (parsed['request_id'] || err_obj['request_id']) : nil
      klass = case status
              when 400 then ValidationError
              when 401 then AuthError
              when 402 then PaymentRequiredError
              when 403 then PermissionError
              when 404 then NotFoundError
              when 409 then ConflictError
              when 429 then RateLimitError
              else ApiError
              end
      klass.new(status: status, code: code, message: msg, hint: hint, request_id: req_id, retry_after: retry_after)
    end
  end
end
