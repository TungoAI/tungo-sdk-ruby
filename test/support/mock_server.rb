# frozen_string_literal: true

require "json"
require "socket"

# A small in-process HTTP/1.1 server for the test suite. It records every request and answers
# with whatever the current handler returns, including the failure modes a real network has:
# dropped connections, truncated bodies, slow responses and streams that are cut by the client.
class MockServer
  Request = Struct.new(:verb, :target, :path, :query, :headers, :body, :connection, keyword_init: true) do
    def json
      JSON.parse(body)
    end
  end

  REASONS = { 200 => "OK", 201 => "Created", 202 => "Accepted", 204 => "No Content" }.freeze

  attr_reader :port

  # A JSON response.
  def self.json(data, status: 200, headers: {})
    { status: status, headers: { "content-type" => "application/json" }.merge(headers), body: JSON.generate(data) }
  end

  # An error response in the API's envelope.
  def self.error(status, type, message: "mock failure", code: nil, headers: {}, extra: {}, request_id: "req_body_1")
    detail = { "type" => type, "message" => message }.merge(extra)
    detail["code"] = code if code
    json({ "type" => "error", "error" => detail, "request_id" => request_id }, status: status, headers: headers)
  end

  # A server-sent event stream sent in the given chunks, +delay+ seconds apart.
  def self.sse(chunks, delay: 0, headers: {})
    { status: 200, headers: { "content-type" => "text/event-stream", "cache-control" => "no-cache" }.merge(headers),
      chunks: Array(chunks), delay: delay }
  end

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @mutex = Mutex.new
    @requests = []
    @connections = 0
    @client_gone = false
    @handler = ->(_request) { MockServer.json({}) }
    @workers = []
    @acceptor = Thread.new { accept_loop }
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  # Sets the handler: it receives the request and the number of requests seen so far
  # (1-based) and returns a response Hash (see .json, .error, .sse) with the optional keys
  # :sleep (seconds before answering), :drop (close without answering), :truncate (cut the body
  # short) and :hang (seconds a chunked response stays open after its last chunk).
  def respond(&handler)
    @mutex.synchronize { @handler = handler }
  end

  def requests
    @mutex.synchronize { @requests.dup }
  end

  # Number of TCP connections accepted so far.
  def connections
    @mutex.synchronize { @connections }
  end

  # True once a write to a streaming client failed because the client closed the connection.
  def client_gone?
    @mutex.synchronize { @client_gone }
  end

  def close
    @acceptor.kill
    @server.close
    @mutex.synchronize { @workers.dup }.each(&:kill)
  rescue IOError
    nil
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      id = @mutex.synchronize { @connections += 1 }
      worker = Thread.new { serve(socket, id) }
      @mutex.synchronize { @workers << worker }
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def serve(socket, id)
    while (request = read_request(socket, id))
      handler, count = @mutex.synchronize do
        @requests << request
        [@handler, @requests.size]
      end
      response = handler.arity == 1 ? handler.call(request) : handler.call(request, count)
      break unless write_response(socket, response)
    end
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close unless socket.closed?
  end

  def read_request(socket, id)
    line = socket.gets("\r\n")
    return nil if line.nil?

    verb, target, = line.force_encoding(Encoding::UTF_8).split
    headers = {}
    while (header = socket.gets("\r\n")) && header != "\r\n"
      name, value = header.chomp.split(":", 2)
      headers[name.downcase] = value.to_s.strip.force_encoding(Encoding::UTF_8)
    end
    body = socket.read(headers["content-length"].to_i).to_s
    path, query = target.split("?", 2)
    Request.new(verb: verb, target: target, path: path, query: query, headers: headers,
                body: body.force_encoding(Encoding::UTF_8), connection: id)
  end

  # Returns false when the connection must not be reused.
  def write_response(socket, response)
    sleep(response[:sleep]) if response[:sleep]
    return false if response[:drop]

    status = response.fetch(:status, 200)
    head = "HTTP/1.1 #{status} #{REASONS.fetch(status, "Status")}\r\n"
    headers = { "x-request-id" => "req_hdr_1" }.merge(response.fetch(:headers, {}).transform_keys(&:downcase))
    return write_chunks(socket, head, headers, response) if response[:chunks]

    body = response.fetch(:body, "").b
    length = response[:truncate] ? body.bytesize + 1000 : body.bytesize
    headers = headers.merge("content-length" => length.to_s) unless status == 204
    socket.write("#{head}#{header_lines(headers)}\r\n#{body}")
    !response[:truncate]
  end

  def header_lines(headers)
    headers.map { |name, value| "#{name}: #{value}\r\n" }.join
  end

  def write_chunks(socket, head, headers, response)
    headers = headers.merge("transfer-encoding" => "chunked")
    socket.write("#{head}#{header_lines(headers)}\r\n")
    response[:chunks].each do |chunk|
      chunk = chunk.b
      socket.write("#{chunk.bytesize.to_s(16)}\r\n#{chunk}\r\n") unless chunk.empty?
      socket.flush
      sleep(response[:delay]) if response[:delay].to_f.positive?
    end
    if response[:hang]
      sleep(response[:hang])
      return false
    end

    socket.write("0\r\n\r\n")
    true
  rescue IOError, SystemCallError
    @mutex.synchronize { @client_gone = true }
    false
  end
end
