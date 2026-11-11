# frozen_string_literal: true

module Tungo
  # One page of a cursor-paginated list (+{ data, next_cursor }+).
  #
  #   page = client.chat.list(limit: 20)
  #   page.data            # the items of this page
  #   page.next_page?      # is there another page?
  #   page = page.next_page
  #
  # A page is Enumerable over its own items. {#auto_paging_each} walks this page and all the
  # following ones, fetching each page only when it is needed.
  class Page
    include Enumerable

    # @return [Array] the typed items of this page
    attr_reader :data
    # @return [String, nil] cursor of the next page; nil or empty on the last page
    attr_reader :next_cursor
    # @return [Tungo::Model] the whole response object (it may carry more than data and next_cursor)
    attr_reader :body
    # @return [Tungo::APIResponse] status and headers of the response
    attr_reader :api_response

    # @api private
    def initialize(body:, cursor:, fetch:, seen: nil)
      @body = body
      data = body[:data]
      @data = data.is_a?(Array) ? data : [].freeze
      next_cursor = body[:next_cursor]
      @next_cursor = next_cursor.is_a?(String) && !next_cursor.empty? ? next_cursor : nil
      @api_response = body.api_response
      @cursor = cursor
      @seen = (seen || [cursor].compact).freeze
      @fetch = fetch
      freeze
    end

    # Yields the items of this page only.
    def each(&)
      return enum_for(:each) unless block_given?

      @data.each(&)
      self
    end

    # @return [Boolean] whether another page exists
    def next_page?
      !@next_cursor.nil?
    end

    # Fetches the next page with the same filters.
    #
    # @return [Tungo::Page]
    # @raise [Tungo::PaginationError] when this is the last page or the API returns a cursor that
    #   was already used on the way to this page
    def next_page
      raise PaginationError, "there is no next page: next_cursor is empty" unless next_page?
      if @seen.include?(@next_cursor)
        raise PaginationError,
              "the API returned the cursor #{@next_cursor.inspect} twice; stopping instead of looping forever"
      end

      @fetch.call(@next_cursor, @seen)
    end

    # Iterates over the items of this page and of every following page. Pages are requested
    # lazily: stopping early stops fetching.
    #
    # @return [Enumerator] when no block is given
    def auto_paging_each(&)
      first = self
      self.class.auto_paging { first }.each(&)
    end

    # @api private
    # @return [Enumerator] a lazy iterator over all items, starting with the page the block returns
    def self.auto_paging
      Enumerator.new do |yielder|
        page = yield
        loop do
          page.data.each { |item| yielder << item }
          break unless page.next_page?

          page = page.next_page
        end
      end
    end

    def inspect
      "#<#{self.class.name} data=#{@data.size} items next_cursor=#{@next_cursor.inspect}>"
    end
  end
end
