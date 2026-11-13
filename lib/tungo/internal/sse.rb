# frozen_string_literal: true

module Tungo
  # One server-sent event as it arrived on the wire.
  #
  # @!attribute event
  #   @return [String] the event name; "message" when the stream did not name it
  # @!attribute data
  #   @return [String] the data lines joined with "\n"
  # @!attribute id
  #   @return [String, nil] the last event id seen so far
  # @!attribute retry
  #   @return [Integer, nil] the reconnection time in milliseconds, when this event set it
  ServerSentEvent = Data.define(:event, :data, :id, :retry) do
    # @return [Object] the data parsed as JSON
    # @raise [Tungo::DecodeError] when the data is not valid JSON
    def json
      Internal::Util.parse_json(data)
    rescue JSON::ParserError => e
      raise DecodeError.new("The #{event.inspect} event does not carry valid JSON: #{e.message}", body: data)
    end
  end

  module Internal
    # Incremental parser of the text/event-stream format (WHATWG HTML, "event stream
    # interpretation"). Feed it the bytes as they arrive; it yields every completed event.
    # Lines may end with LF, CRLF or a bare CR, and both events and UTF-8 sequences may be split
    # across chunks. An event that is not terminated by a blank line is discarded.
    class SSEDecoder
      BOM = "\xEF\xBB\xBF".b.freeze
      LINE_END = /\r\n|\n|\r/n

      def initialize
        @buffer = String.new(encoding: Encoding::BINARY)
        @start = true
        @scanned = 0
        @last_id = nil
        reset_event
      end

      # @param chunk [String] the next bytes of the stream
      # @yieldparam event [Tungo::ServerSentEvent]
      def feed(chunk, &)
        @buffer << chunk.b
        return if @start && !bom_resolved?

        offset = 0
        scan = @scanned
        while (index = @buffer.index(LINE_END, scan))
          terminator = @buffer.getbyte(index) == 13 && @buffer.getbyte(index + 1) == 10 ? 2 : 1
          # A CR at the very end may be the first half of a CRLF that is still on its way.
          break if terminator == 1 && @buffer.getbyte(index) == 13 && index == @buffer.bytesize - 1

          line(@buffer.byteslice(offset, index - offset), &)
          offset = scan = index + terminator
        end
        @buffer = @buffer.byteslice(offset, @buffer.bytesize - offset) if offset.positive?
        # Only the last byte (a possible lone CR) has to be looked at again, which keeps very
        # long lines linear.
        @scanned = [@buffer.bytesize - 1, 0].max
        nil
      end

      # Signals the end of the stream. A trailing CR completes its line; an event without its
      # terminating blank line is dropped.
      def finish(&)
        @start = false
        line(@buffer.byteslice(0, @buffer.bytesize - 1), &) if @buffer.end_with?("\r")
        @buffer = String.new(encoding: Encoding::BINARY)
        @scanned = 0
        reset_event
        nil
      end

      private

      # Returns false while it is still unknown whether the stream starts with a byte-order mark.
      def bom_resolved?
        return false if @buffer.bytesize < BOM.bytesize && BOM.start_with?(@buffer)

        @buffer = @buffer.byteslice(BOM.bytesize, @buffer.bytesize - BOM.bytesize) if @buffer.start_with?(BOM)
        @start = false
        true
      end

      def reset_event
        @event = nil
        @data = nil
        @retry = nil
      end

      def line(bytes, &)
        return dispatch(&) if bytes.empty?
        return if bytes.getbyte(0) == 58 # ":" starts a comment

        name, value = bytes.split(":", 2)
        value = (value || "").delete_prefix(" ")
        field(name, value.force_encoding(Encoding::UTF_8).scrub)
      end

      def field(name, value)
        case name
        when "event" then @event = value
        when "data" then @data = @data ? "#{@data}\n#{value}" : value
        when "id" then @last_id = value unless value.include?("\0")
        when "retry" then @retry = value.to_i if value.match?(/\A[0-9]+\z/)
        end
      end

      def dispatch
        data = @data
        event = @event
        retry_ms = @retry
        reset_event
        return if data.nil?

        yield ServerSentEvent.new(event: event.nil? || event.empty? ? "message" : event, data: data, id: @last_id,
                                  retry: retry_ms)
      end
    end

    # A stream call repeated with the same Idempotency-Key after its chat turn finished: the
    # server answers the stored ChatTurnResult as JSON with Idempotent-Replayed: true.
    module ChatReplay
      module_function

      # Whether a stream call was answered with a stored result replayed by Idempotency-Key.
      def replay?(response)
        type = response.headers["content-type"].to_s.split(";").first.to_s.strip
        type.casecmp?("application/json") && response.headers["idempotent-replayed"].to_s.strip.casecmp?("true")
      end

      # Turns a replayed ChatTurnResult into the event stream of the turn it stands for: text (the
      # answer), proposal, question, citation, error, choice and next events, then done. The dialog id
      # and the turn number, which a replay carries only in the body, become the X-Dialog-Id and
      # X-Turn-No headers when they are missing.
      #
      # @raise [Tungo::DecodeError] when the body is not a chat turn result
      def event_stream(response)
        body = begin
          response.read
        ensure
          response.close
        end
        result = parse(body)
        unless result.is_a?(Hash) && result["dialog_id"].is_a?(String)
          raise DecodeError.new("The API replayed status #{response.status} to a stream request with a body that " \
                                "is not a chat turn result",
                                api_response: APIResponse.new(status: response.status, headers: response.headers),
                                body: body)
        end
        headers = response.headers.dup
        headers["x-dialog-id"] = result["dialog_id"] if headers["x-dialog-id"].to_s.empty?
        turn_no = result["turn_no"]
        headers["x-turn-no"] = turn_no.to_s if turn_no.is_a?(Integer) && headers["x-turn-no"].to_s.empty?
        Transport::Response.new(status: response.status, headers: headers, chunks: [events(result, headers)])
      end

      def parse(body)
        Util.parse_json(Util.text(body))
      rescue JSON::ParserError, EncodingError, ArgumentError
        nil
      end

      def events(result, headers)
        out = +""
        emit = ->(type, event) { out << "event: #{type}\ndata: #{Util.generate_json(event.merge("type" => type))}\n\n" }
        entries = ->(key) { result[key].is_a?(Array) ? result[key].grep(Hash) : [] }
        answer = result["answer"].is_a?(String) ? result["answer"] : ""
        emit.call("text", { "delta" => answer }) unless answer.empty?
        entries.call("proposals").each do |proposal|
          emit.call("proposal", proposal.except("id").merge("proposal_id" => proposal["id"]))
        end
        entries.call("questions").each { |question| emit.call("question", question) }
        entries.call("citations").each { |citation| emit.call("citation", citation) }
        request_id = headers["x-request-id"].to_s
        entries.call("errors").each do |error|
          emit.call("error", { "error" => error, "request_id" => request_id.empty? ? nil : request_id })
        end
        emit.call("done", done(result, answer, emit))
        out
      end

      # The next event of a live turn, which ends its finished answer right before done: the stored
      # result keeps it as followups and next_action.
      def next_event(result, emit)
        followups = result["followups"].is_a?(Array) ? result["followups"] : []
        action = result["next_action"].is_a?(Hash) ? result["next_action"] : nil
        return if followups.empty? && action.nil?

        emit.call("next", { "followups" => followups, "action" => action })
      end

      # The done event; emits the choice event of an open question and the next event first.
      def done(result, answer, emit)
        event = { "answer" => answer }
        event["stop_reason"] = result["stop_reason"] if result["stop_reason"].is_a?(String)
        usage = result["usage"]
        if usage.is_a?(Hash)
          event["usage"] = usage.except("cost_tiyn")
          event["cost_tiyn"] = usage["cost_tiyn"] if usage.key?("cost_tiyn")
        end
        pending = result["pending_question"]
        if pending.is_a?(Hash)
          emit.call("choice", pending)
          event["choice_id"] = pending["choice_id"] if pending.key?("choice_id")
        end
        next_event(result, emit)
        event
      end
    end
  end
end
