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
  end
end
