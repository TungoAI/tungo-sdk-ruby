# frozen_string_literal: true

require 'base64'
require 'json'
require 'openssl'
require 'securerandom'
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
  end

  module Webhooks
    module_function

    def sign_hook_payload(raw_body, secret)
      'sha256=' + OpenSSL::HMAC.hexdigest('SHA256', secret, raw_body)
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
        part.start_with?('v1,') && OpenSSL.fixed_length_secure_compare(expected_b64, part.sub(/\Av1,/, ''))
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
      base_url: ENV.fetch('TUNGO_BASE_URL', 'https://api.tungo.ai'),
      workspace_id: ENV['TUNGO_WORKSPACE_ID'],
      company_id: ENV['TUNGO_COMPANY_ID']
    )
      @api_key = api_key
      @base_url = base_url.sub(%r{/\z}, '')
      @workspace_id = workspace_id
      @company_id = company_id
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
    def ask(prompt, company_id: nil, conversation_id: nil)
      body = { 'message' => prompt, 'stream' => false }
      body['conversation_id'] = conversation_id if conversation_id
      params = company_id ? { 'co' => company_id } : {}
      @chat.create(body: body, params: params)
    end

    def request(_method, _path, query: {}, body: nil, auth: 'key', idempotent: false, retry_safe: false)
      {}
    end

    def request_stream(_method, _path, query: {}, body: nil, auth: 'key')
      []
    end
  end
end
