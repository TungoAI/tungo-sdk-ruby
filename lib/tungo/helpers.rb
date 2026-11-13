# frozen_string_literal: true

module Tungo
  # Convenience methods of {Tungo::Client} built on top of the generated resources.
  module Helpers
    # States of an automation run after which it no longer changes.
    RUN_TERMINAL_STATES = %w[done error skipped cancelled].freeze

    # Asks the AI accountant one question and waits for the complete answer (a non-streaming
    # chat turn; the default timeout is {Tungo::Client#chat_timeout}).
    #
    # @param message [String] the question
    # @param dialog_id [String] continue this dialog instead of starting a new one
    # @param company_id [String, nil] overrides the client's company
    # @param raise_on_error [Boolean] raise the typed error when the turn reports one
    # @return [Tungo::Models::ChatTurnResult]
    # @raise [Tungo::APIError] when the turn reports an error and +raise_on_error+ is true
    def ask(message, dialog_id: OMIT, company_id: nil, raise_on_error: true, request_options: nil)
      result = chat.create(message: message, dialog_id: dialog_id, company_id: company_id,
                           request_options: request_options)
      failure = result.errors.is_a?(Array) ? result.errors.first : nil
      return result if failure.nil? || !raise_on_error

      headers = result.api_response ? result.api_response.headers : {}
      event = { "type" => "error", "error" => Internal::Type.wire(failure), "request_id" => headers["x-request-id"] }
      raise APIError.from_event(event, headers: headers)
    end

    # Posts an event to an incoming hook (+POST /hooks/{token}+). The API key is never sent.
    # With a +secret+ the exact bytes of the body are signed in the +X-Signature+ header, or in
    # +signature_header:+ for a hook created with its own signature_header.
    #
    # @param token [String] the hook token (+th_...+)
    # @param payload [String, Hash, Array, Tungo::Model, nil] a String is sent byte for byte;
    #   anything else is sent as JSON
    # @param secret [String, nil] the hook's signing secret
    # @param signature_header [String, nil] the hook's own signature_header (default X-Signature)
    # @param options [Hash] the other keyword arguments of +automations.post_hook+
    # @return [Tungo::Models::AutomationHookAccepted]
    def send_hook(token, payload = nil, secret: nil, **)
      automations.post_hook(token, payload, secret: secret, **)
    end

    # Verifies a webhook with the client's webhook secret (or the one given) and returns its
    # typed event. See {Tungo::Webhooks.verify_webhook}.
    #
    # @return [Tungo::Model] one of the {Tungo::Models::WebhookEvent} variants
    # @raise [Tungo::WebhookVerificationError]
    def verify_webhook(payload, headers, secret: nil, tolerance: Webhooks::DEFAULT_TOLERANCE, now: nil)
      Webhooks.verify_webhook(payload, headers, secret || webhook_secret, tolerance: tolerance, now: now)
    end

    # Starts a scenario and waits until its run reaches a terminal state.
    #
    # @param scenario_id [String]
    # @param event_id [String] id of the triggering event, for de-duplication
    # @param timeout [Numeric] seconds to wait for the run to finish
    # @return [Tungo::Models::AutomationRunDetail]
    # @raise [Tungo::WaitTimeoutError] when the run is still in progress after +timeout+ seconds
    def run_scenario_and_wait(scenario_id, event_id: OMIT, company_id: nil, timeout: 600, poll_interval: 1.0,
                              max_poll_interval: 5.0, request_options: nil)
      run = automations.run_scenario(scenario_id, event_id: event_id, company_id: company_id,
                                                  request_options: request_options)
      wait_for_run(run.id, company_id: company_id, timeout: timeout, poll_interval: poll_interval,
                           max_poll_interval: max_poll_interval, request_options: request_options)
    end

    # Polls an automation run until it reaches a terminal state (done, error, skipped or
    # cancelled). The pause between polls grows from +poll_interval+ to +max_poll_interval+.
    #
    # @param run_id [String]
    # @param timeout [Numeric] seconds to wait
    # @return [Tungo::Models::AutomationRunDetail]
    # @raise [Tungo::WaitTimeoutError] when the run is still in progress after +timeout+ seconds
    # @raise [Tungo::DecodeError] when the response carries no state
    def wait_for_run(run_id, company_id: nil, timeout: 600, poll_interval: 1.0, max_poll_interval: 5.0,
                     request_options: nil)
      poll("run #{run_id}", timeout, poll_interval, max_poll_interval) do
        run = automations.get_run(run_id, company_id: company_id, request_options: request_options)
        unless run.state.is_a?(String)
          raise DecodeError.new("The run has no state", api_response: run.api_response, body: run.to_json)
        end

        RUN_TERMINAL_STATES.include?(run.state) ? run : nil
      end
    end

    # Polls a batch job until it stops running.
    #
    # @param batch_id [String]
    # @param timeout [Numeric] seconds to wait
    # @return [Tungo::Models::BatchJob]
    # @raise [Tungo::WaitTimeoutError] when the job is still running after +timeout+ seconds
    # @raise [Tungo::DecodeError] when the response does not say whether the job is running
    def wait_for_batch(batch_id, company_id: nil, timeout: 600, poll_interval: 1.0, max_poll_interval: 5.0,
                       request_options: nil)
      poll("batch #{batch_id}", timeout, poll_interval, max_poll_interval) do
        job = batches.get(batch_id, company_id: company_id, request_options: request_options)
        unless [true, false].include?(job.running)
          raise DecodeError.new("The batch job does not say whether it is running", api_response: job.api_response,
                                                                                    body: job.to_json)
        end

        job.running ? nil : job
      end
    end

    # Uploads a bank statement (1CClientBankExchange) for parsing into proposals.
    #
    # @param file [String, Pathname, #read] the bytes of the file exactly as the bank produced
    #   them, a Pathname to read them from, or an open IO
    # @param file_name [String] shown in the job title; defaults to the Pathname's base name
    # @param limit [Integer] how many rows to process
    # @return [Tungo::Models::BatchJob]
    def upload_bank_statement(file, file_name: OMIT, limit: OMIT, company_id: nil, request_options: nil)
      file_name = file.basename.to_s if OMIT.equal?(file_name) && file.is_a?(Pathname)
      bytes = case file
              when Pathname then file.binread
              when String then file
              else file.respond_to?(:read) ? file.read : nil
              end
      raise ValidationError, "file must be a String of bytes, a Pathname or an IO" unless bytes.is_a?(String)

      batches.create_bank_statement(file: Base64.strict_encode64(bytes), file_name: file_name, limit: limit,
                                    company_id: company_id, request_options: request_options)
    end

    private

    def poll(what, timeout, interval, max_interval)
      unless [timeout, interval, max_interval].all? { |value| value.is_a?(Numeric) && value.positive? }
        raise ValidationError, "timeout, poll_interval and max_poll_interval must be positive numbers"
      end

      deadline = Internal::Util.monotonic + timeout
      loop do
        result = yield
        return result unless result.nil?

        remaining = deadline - Internal::Util.monotonic
        raise WaitTimeoutError, "#{what} did not finish within #{timeout} s" if remaining <= 0

        sleep([interval, remaining].min)
        interval = [interval * 1.5, max_interval].min
      end
    end
  end
end
