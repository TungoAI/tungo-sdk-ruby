# frozen_string_literal: true

module Tungo
  # A file the API returned: its bytes, its name and content type, and the response behind it.
  # Returned by the operations that download a file, such as +client.proposals.export+. The whole
  # body is held in memory.
  #
  #   file = client.proposals.export("P-000123", format: "pdf")
  #   File.binwrite(File.basename(file.filename || "proposal.pdf"), file.content)
  class DownloadedFile
    # @return [String] the bytes of the file exactly as sent (binary, ASCII-8BIT)
    attr_reader :content
    # @return [Tungo::APIResponse] status and headers of the response
    attr_reader :api_response

    # @api private
    def initialize(content:, api_response:)
      @content = content.b.freeze
      @api_response = api_response
      freeze
    end

    # The file name from the Content-Disposition header: the UTF-8 +filename*+ when it is usable,
    # otherwise +filename+. It is the server's suggestion as sent, not a safe path.
    #
    # @return [String, nil] nil when the response names no file
    def filename
      self.class.filename_from(@api_response["content-disposition"])
    end

    # @return [String, nil] the Content-Type header as sent, parameters included
    def content_type
      @api_response["content-type"]
    end

    # @return [String, nil] the request id to quote to support (+x-request-id+)
    def request_id
      @api_response.request_id
    end

    # @return [Hash{String=>String}] response headers with lower-case names
    def headers
      @api_response.headers
    end

    # @return [Integer] the size of the file in bytes
    def size
      @content.bytesize
    end

    # The bytes are never shown, only their number.
    def inspect
      "#<#{self.class.name} filename=#{filename.inspect} content_type=#{content_type.inspect} size=#{size} " \
        "request_id=#{request_id.inspect}>"
    end
    alias to_s inspect

    def pretty_print(printer)
      printer.text(inspect)
    end

    # The file name a Content-Disposition header gives. Parameters are split on +;+ outside quoted
    # strings and their names compared case-insensitively; +filename*+ (RFC 5987) wins over
    # +filename+ when its charset is UTF-8 and it decodes to valid UTF-8.
    #
    # @param header [String, nil]
    # @return [String, nil] nil when there is no name or it is empty
    def self.filename_from(header)
      return nil if header.nil?

      params = disposition_params(text(header.to_s))
      extended = extended_value(params["filename*"])
      return extended if extended

      name = params["filename"]
      name.nil? || name.empty? ? nil : name
    end

    # A header read off the wire may come as binary: it is taken as UTF-8 when it is valid UTF-8.
    def self.text(value)
      utf8 = value.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : value
    end

    def self.disposition_params(header)
      parts = split_params(header)
      parts.drop(1).each_with_object({}) do |part, params|
        name, separator, value = part.partition("=")
        next if separator.empty?

        name = name.strip.downcase
        value = value.strip
        value = unquote(value) if value.length >= 2 && value.start_with?('"') && value.end_with?('"')
        params[name] = value unless params.key?(name)
      end
    end

    def self.split_params(header)
      parts = [+""]
      quoted = escaped = false
      header.each_char do |char|
        if escaped
          escaped = false
        elsif quoted && char == "\\"
          escaped = true
        elsif char == '"'
          quoted = !quoted
        elsif char == ";" && !quoted
          parts << +""
          next
        end
        parts.last << char
      end
      parts
    end

    def self.unquote(value)
      out = +""
      escape = false
      value[1...-1].each_char do |char|
        if !escape && char == "\\"
          escape = true
          next
        end
        escape = false
        out << char
      end
      out
    end

    def self.extended_value(value)
      return nil if value.nil?

      charset, separator, rest = value.partition("'")
      return nil if separator.empty? || !charset.casecmp?("utf-8")

      _language, separator, encoded = rest.partition("'")
      return nil if separator.empty?

      bytes = percent_decode(encoded)
      return nil if bytes.nil? || bytes.empty?

      text = bytes.force_encoding(Encoding::UTF_8)
      text.valid_encoding? ? text : nil
    end

    def self.percent_decode(text)
      raw = text.b
      out = String.new(encoding: Encoding::BINARY)
      index = 0
      while index < raw.bytesize
        if raw.getbyte(index) == 0x25
          pair = raw.byteslice(index + 1, 2)
          return nil unless pair.match?(/\A\h\h\z/)

          out << pair.to_i(16).chr
          index += 3
        else
          out << raw.getbyte(index).chr
          index += 1
        end
      end
      out
    end

    private_class_method :text, :disposition_params, :split_params, :unquote, :extended_value, :percent_decode
  end
end
