# frozen_string_literal: true

module Tungo
  # The HTTP layer of the client. The default implementation is {Tungo::Transport::NetHTTP};
  # any object with the same +execute+ and +close+ methods can be passed to
  # +Tungo::Client.new(transport: ...)+, for example to route requests through a test double.
  module Transport
    # Headers whose values are credentials: never printed, and never sent to an operation that
    # is not authenticated with the API key unless the call itself asks for it.
    CREDENTIAL_HEADERS = %w[x-api-key authorization proxy-authorization cookie].freeze

    # One HTTP request, ready to be sent.
    #
    # @!attribute verb
    #   @return [String] upper-case HTTP method
    # @!attribute url
    #   @return [URI::HTTP]
    # @!attribute headers
    #   @return [Hash{String=>String}]
    # @!attribute body
    #   @return [String, nil] the exact bytes of the body
    # @!attribute timeout
    #   @return [Numeric, nil] seconds for the whole exchange including the body; nil for a stream
    # @!attribute connect_timeout
    #   @return [Numeric] seconds to establish the connection
    # @!attribute idle_timeout
    #   @return [Numeric] seconds without any byte before the exchange is abandoned
    # @!attribute route
    #   @return [String, nil] the path template of the operation, such as +/hooks/{token}+
    Request = Data.define(:verb, :url, :headers, :body, :timeout, :connect_timeout, :idle_timeout, :route) do
      def initialize(route: nil, **)
        super
      end

      # What error messages and logs call the request: the method and the path template. The path
      # itself and the query string are never shown, they may hold secrets (an incoming hook token).
      #
      # @return [String]
      def label
        route ? "#{verb} #{route}" : "#{verb} request"
      end

      # Never shows what may hold a secret: the values of credential headers (the API key), the
      # path and the query string (an incoming hook token) and the body.
      #
      # @return [String]
      def inspect
        shown = headers.to_h do |name, value|
          [name, CREDENTIAL_HEADERS.include?(name.to_s.downcase) ? "[REDACTED]" : value]
        end
        "#<#{self.class.name} #{label} host=#{url.host.inspect} headers=#{shown.inspect} " \
          "body=#{body.nil? ? "nil" : "#{body.bytesize} bytes"} timeout=#{timeout.inspect} " \
          "connect_timeout=#{connect_timeout.inspect} idle_timeout=#{idle_timeout.inspect}>"
      end
      alias_method :to_s, :inspect

      def pretty_print(printer)
        printer.text(inspect)
      end
    end

    # An HTTP response whose body is read on demand.
    class Response
      # @return [Integer]
      attr_reader :status
      # @return [Hash{String=>String}] headers with lower-case names
      attr_reader :headers

      # @param headers [Hash] response headers; the names are lower-cased
      # @param chunks [Enumerable<String>, #call] the body piece by piece: an Array, an Enumerator,
      #   or a callable that returns the next piece and nil at the end of the body
      # @param on_close [#call, nil] releases the connection
      def initialize(status:, headers:, chunks:, on_close: nil)
        @status = status
        @headers = Internal::Util.normalize_headers(headers).freeze
        @chunks = pull(chunks)
        @on_close = on_close
        @finished = false
        @closed = false
      end

      # Yields the body as it arrives. Stops when the body ends or the response is closed. It may
      # be called from any thread, but from one at a time.
      #
      # @yieldparam chunk [String] binary bytes
      def each_chunk
        until @finished || @closed
          chunk = @chunks.call
          if chunk.nil?
            @finished = true
            break
          end
          yield chunk
        end
        nil
      end

      # @return [String] the rest of the body (binary)
      def read
        buffer = String.new(encoding: Encoding::BINARY)
        each_chunk { |chunk| buffer << chunk }
        buffer
      end

      # Abandons the rest of the body and releases the connection. Safe to call more than once.
      def close
        return if @closed

        @closed = true
        @on_close&.call
        nil
      end

      # @return [Boolean]
      def closed?
        @closed
      end

      private

      def pull(chunks)
        return chunks if chunks.respond_to?(:call)

        source = chunks.is_a?(Enumerator) ? chunks : chunks.each
        lambda do
          source.next
        rescue StopIteration
          nil
        end
      end
    end

    # One exchange in progress: a worker thread talks to the socket and hands the status line
    # and the body pieces over a queue of one element. The reader may therefore be any thread
    # (a stream opened on one thread can be read on another), and closing is deterministic:
    # the worker is interrupted, closes its connection, and close returns after that.
    #
    # @api private
    class Exchange
      # Interrupts the worker; not a StandardError, so that no rescue in between swallows it.
      class Abandoned < Exception; end # rubocop:disable Lint/InheritException

      def initialize(&work)
        @queue = SizedQueue.new(1)
        @thread = Thread.new { pump(work) }
        @thread.report_on_exception = false
      end

      # @return [Array] the next item of the worker: [:head, status, headers] or [:chunk, bytes];
      #   nil at the end of the body
      # @raise [Tungo::Error] what ended the exchange
      def next
        item = @queue.pop
        return nil if item.nil?
        raise item.last if item.first == :error

        item
      end

      # Stops the worker and waits until it has released its connection.
      def close
        abandon
        @thread.join unless @thread.equal?(Thread.current)
        nil
      end

      # Stops the worker without waiting for it.
      def abandon(*)
        @queue.close
        @thread.raise(Abandoned) if @thread.alive?
        nil
      rescue ThreadError
        nil
      end

      # Runs the block with interruption by {#close} allowed; everywhere else in the worker it
      # is deferred, so that the connection is always put back or closed.
      def self.interruptible(&)
        Thread.handle_interrupt(Abandoned => :immediate, &)
      end

      private

      def pump(work)
        Thread.handle_interrupt(Abandoned => :never) do
          work.call(->(item) { @queue.push(item) })
        rescue Abandoned, ClosedQueueError
          nil
        rescue Exception => e # rubocop:disable Lint/RescueException
          hand_over(e)
        ensure
          @queue.close
        end
      rescue Abandoned
        nil
      end

      def hand_over(error)
        @queue.push([:error, error])
      rescue ClosedQueueError
        nil
      end
    end

    # Net::HTTP transport with persistent connections.
    #
    # Connections are kept per origin and reused (HTTP keep-alive). The pool is thread-safe; a
    # connection is used by one request at a time. The body is streamed: a response is returned
    # as soon as its headers arrive. Every exchange runs on a worker thread of its own, so a
    # response may be read and closed from any thread.
    class NetHTTP
      # @param max_idle_connections [Integer] idle connections kept per origin
      # @param keep_alive_timeout [Numeric] seconds an idle connection may be reused
      # @param proxy [String, URI, nil] HTTP proxy URL; by default the +http_proxy+ environment
      #   variables are honoured, as with Net::HTTP itself
      # @yieldparam http [Net::HTTP] every new connection before it is opened, e.g. to set a CA file
      def initialize(max_idle_connections: 8, keep_alive_timeout: 30, proxy: nil, &configure)
        @max_idle_connections = max_idle_connections
        @keep_alive_timeout = keep_alive_timeout
        @proxy = proxy && URI(proxy.to_s)
        @configure = configure
        @idle = {}
        @mutex = Mutex.new
      end

      # Sends the request and returns as soon as the response headers have arrived.
      #
      # @param request [Tungo::Transport::Request]
      # @return [Tungo::Transport::Response]
      # @raise [Tungo::TimeoutError, Tungo::ConnectionError]
      def execute(request)
        exchange = Exchange.new { |emit| run(request, emit) }
        opened = false
        begin
          _, status, headers = exchange.next
          response = Response.new(status: status, headers: headers, chunks: -> { exchange.next&.last },
                                  on_close: -> { exchange.close })
          # A response that is dropped without being read or closed still releases its connection.
          ObjectSpace.define_finalizer(response, exchange.method(:abandon))
          opened = true
          response
        ensure
          # Also on an exception raised into the caller from outside, such as Timeout.timeout.
          exchange.close unless opened
        end
      end

      # Closes every idle connection.
      def close
        connections = @mutex.synchronize do
          all = @idle.values.flatten
          @idle.clear
          all
        end
        connections.each { |connection| finish(connection) }
        nil
      end

      def inspect
        "#<#{self.class.name} max_idle_connections=#{@max_idle_connections}>"
      end

      private

      # Runs on the worker thread: emits [:head, status, headers] first, then the body chunks.
      def run(request, emit)
        deadline = request.timeout && (Internal::Util.monotonic + request.timeout)
        origin = "#{request.url.scheme}://#{request.url.host}:#{request.url.port}"
        connection = checkout(origin, request.url)
        reusable = false
        begin
          Exchange.interruptible { exchange(connection, request, deadline, emit) { reusable = true } }
        rescue Timeout::Error, Errno::ETIMEDOUT => e
          # Net::OpenTimeout, Net::ReadTimeout and Net::WriteTimeout are Timeout::Errors. A
          # Timeout.timeout around the call is raised in the caller's thread, never here.
          raise Tungo::TimeoutError, "#{request.label} timed out (#{e.class}: #{e.message})"
        rescue Tungo::Error
          raise
        rescue StandardError => e
          raise Tungo::ConnectionError,
                "#{request.label} failed to connect or lost the connection " \
                "(#{e.class}: #{e.message})"
        ensure
          reusable ? checkin(origin, connection) : finish(connection)
        end
      end

      def exchange(connection, request, deadline, emit)
        apply_timeouts(connection, request, deadline)
        unless connection.started?
          connection.start
          # Connecting took its share of the total timeout: the request gets what is left.
          apply_timeouts(connection, request, deadline)
        end
        connection.request(build(request)) do |response|
          # A body that ends before its Content-Length is an error, not a short success.
          response.ignore_eof = false
          emit.call([:head, response.code.to_i, response.to_hash])
          response.read_body do |chunk|
            emit.call([:chunk, chunk])
            apply_timeouts(connection, request, deadline)
          end
        end
        yield
      end

      # The total timeout covers the whole exchange: every socket operation gets what is left.
      def apply_timeouts(connection, request, deadline)
        if deadline.nil?
          connection.open_timeout = request.connect_timeout
          connection.read_timeout = request.idle_timeout
          connection.write_timeout = request.idle_timeout
          return
        end
        remaining = deadline - Internal::Util.monotonic
        if remaining <= 0
          raise Tungo::TimeoutError,
                "#{request.label} did not finish within #{request.timeout} s"
        end

        connection.open_timeout = [remaining, request.connect_timeout].min
        connection.read_timeout = [remaining, request.idle_timeout].min
        connection.write_timeout = [remaining, request.idle_timeout].min
      end

      def build(request)
        has_body = !request.body.nil?
        message = Net::HTTPGenericRequest.new(request.verb, has_body, request.verb != "HEAD",
                                              request.url.request_uri)
        request.headers.each { |name, value| message[name] = value }
        if has_body
          message.body = request.body
        elsif %w[POST PUT PATCH].include?(request.verb)
          message["Content-Length"] = "0"
        end
        message
      end

      def checkout(origin, url)
        connection = @mutex.synchronize { @idle[origin]&.pop }
        connection || connect(url)
      end

      def checkin(origin, connection)
        keep = @mutex.synchronize do
          idle = (@idle[origin] ||= [])
          idle.size < @max_idle_connections && idle.push(connection)
        end
        finish(connection) unless keep
      end

      def connect(url)
        connection = if @proxy
                       Net::HTTP.new(url.host, url.port, @proxy.host, @proxy.port, @proxy.user, @proxy.password)
                     else
                       Net::HTTP.new(url.host, url.port)
                     end
        connection.use_ssl = url.scheme == "https"
        # Repeating a request is decided by the client's retry policy, never silently by Net::HTTP.
        connection.max_retries = 0
        connection.keep_alive_timeout = @keep_alive_timeout
        @configure&.call(connection)
        connection
      end

      def finish(connection)
        connection.finish if connection.started?
      rescue StandardError
        nil
      end
    end
  end
end
