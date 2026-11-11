# frozen_string_literal: true

module Tungo
  # A server-sent event stream that delivers typed events as they arrive.
  #
  #   stream = client.feed.list_events
  #   stream.each { |item| puts item.title }
  #
  # The connection is closed when the block finishes, when it is left early (+break+, an
  # exception) or when {#close} is called. A stream can be iterated once. It may be handed to
  # another thread and read or closed there; it must not be read by two threads at once.
  class Stream
    include Enumerable

    # @api private
    SKIP = Object.new.freeze

    # @return [Tungo::APIResponse] status and headers of the response
    attr_reader :api_response
    # @return [String, nil] id of the last event received, for reconnecting with +last_event_id:+
    attr_reader :last_event_id

    # @api private
    def initialize(response:, decode:)
      @response = response
      @api_response = APIResponse.new(status: response.status, headers: response.headers)
      @decode = decode
      @started = false
      @last_event_id = nil
    end

    # Yields every typed event as it arrives; heart-beats (+ping+) are skipped.
    #
    # @yieldparam event [Tungo::Model]
    # @return [Enumerator] when no block is given
    # @raise [Tungo::DecodeError] when an event does not carry valid JSON
    def each
      return enum_for(:each) unless block_given?

      each_sse do |sse|
        event = @decode.call(sse)
        yield event unless SKIP.equal?(event)
      end
    end

    # Yields the raw server-sent events, heart-beats included.
    #
    # @yieldparam event [Tungo::ServerSentEvent]
    # @return [Enumerator] when no block is given
    def each_sse
      return enum_for(:each_sse) unless block_given?
      raise Tungo::Error, "the stream has already been consumed" if @started

      @started = true
      decoder = Internal::SSEDecoder.new
      handle = lambda do |sse|
        @last_event_id = sse.id
        yield sse
      end
      begin
        @response.each_chunk { |chunk| decoder.feed(chunk, &handle) }
        decoder.finish(&handle)
      ensure
        close
      end
      self
    end

    # Closes the connection. Safe to call more than once.
    def close
      @response.close
      nil
    end

    # @return [Boolean]
    def closed?
      @response.closed?
    end

    def inspect
      "#<#{self.class.name} status=#{@api_response.status} closed=#{closed?}>"
    end
  end

  # The outcome of one chat turn, accumulated from its stream.
  #
  # @!attribute dialog_id
  #   @return [String, nil] id of the dialog (+X-Dialog-Id+ response header)
  # @!attribute turn_no
  #   @return [Integer, nil] number of the turn (+X-Turn-No+ response header)
  # @!attribute text
  #   @return [String] the final answer
  # @!attribute stop_reason
  #   @return [String, nil] why the turn ended; nil only when the turn ended with an +error+ event
  #     instead of +done+
  # @!attribute cost_tiyn
  #   @return [Integer, nil] cost of the turn in tiyn
  # @!attribute usage
  #   @return [Tungo::Models::ChatUsage, nil] token usage
  # @!attribute choice_id
  #   @return [String, nil] id of the question the assistant is waiting an answer for
  # @!attribute error
  #   @return [Tungo::Model, nil] the first +error+ event of the turn
  # @!attribute events
  #   @return [Array<Tungo::Model>] every event of the turn in order
  ChatTurn = Data.define(:dialog_id, :turn_no, :text, :stop_reason, :cost_tiyn, :usage, :choice_id, :error, :events)

  # The stream of one chat turn (+chat.create_stream+, +chat.answer_stream+).
  #
  #   stream = client.chat.create_stream(message: "...")
  #   stream.each_text { |delta| print delta }
  class ChatStream < Stream
    # @return [String, nil] id of the dialog (+X-Dialog-Id+ response header)
    def dialog_id
      api_response["x-dialog-id"]
    end

    # @return [Integer, nil] number of the turn (+X-Turn-No+ response header)
    def turn_no
      value = api_response["x-turn-no"].to_s
      value.match?(/\A[0-9]+\z/) ? value.to_i : nil
    end

    # Yields the text of the answer piece by piece and returns the accumulated turn.
    #
    # @yieldparam delta [String]
    # @return [Tungo::ChatTurn]
    # @raise [Tungo::APIError] when the turn reported an error
    # @raise [Tungo::DecodeError] when the stream ended before the +done+ event
    def each_text
      accumulate { |event| yield event[:delta].to_s if event[:type] == "text" }
    end

    # Consumes the stream and returns the accumulated turn. The final answer is the text
    # deltas, minus the deltas of every step that a later +progress+ event names, replaced by
    # +done.answer+ when the API sends it.
    #
    # @param raise_on_error [Boolean] raise the typed error of a mid-stream +error+ event once
    #   the stream has ended; with false the event is returned in {Tungo::ChatTurn#error}
    # @yieldparam event [Tungo::Model] every event as it arrives
    # @return [Tungo::ChatTurn]
    # @raise [Tungo::APIError] when the turn reported an error and +raise_on_error+ is true
    # @raise [Tungo::DecodeError] when the stream ended with neither a +done+ nor an +error+ event:
    #   the answer is incomplete and is never returned as a finished turn. Iterating the events
    #   with +each+ simply ends in that case
    def accumulate(raise_on_error: true)
      state = { segments: [], events: [], error: nil, done: nil }
      each do |event|
        collect(state, event)
        yield event if block_given?
      end
      raise APIError.from_event(state[:error], headers: api_response.headers) if state[:error] && raise_on_error
      raise incomplete(state) if state[:done].nil? && state[:error].nil?

      chat_turn(state)
    end

    private

    def incomplete(state)
      DecodeError.new("The chat stream ended before completion: no \"done\" event was received. The request " \
                      "itself was accepted and the turn may still be running: read it again with " \
                      "chat.list_events instead of sending the message once more",
                      api_response: api_response, body: state[:segments].map(&:last).join)
    end

    def collect(state, event)
      state[:events] << event
      case event[:type]
      when "text" then state[:segments] << [event[:step], event[:delta].to_s]
      when "progress" then state[:segments].reject! { |step, _| !step.nil? && step == event[:step] }
      when "error" then state[:error] ||= event
      when "done" then state[:done] = event
      end
    end

    def chat_turn(state)
      done = state[:done]
      answer = done && done[:answer]
      ChatTurn.new(
        dialog_id: dialog_id, turn_no: turn_no,
        text: answer.is_a?(String) ? answer : state[:segments].map(&:last).join,
        stop_reason: done && done[:stop_reason], cost_tiyn: done && done[:cost_tiyn],
        usage: done && done[:usage], choice_id: done && done[:choice_id],
        error: state[:error], events: state[:events].freeze
      )
    end
  end
end
