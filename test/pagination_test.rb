# frozen_string_literal: true

require_relative "test_helper"

class PaginationTest < TungoTestCase
  PAGES = {
    nil => { "data" => [{ "id" => "P-1" }, { "id" => "P-2" }], "next_cursor" => "c2" },
    "c2" => { "data" => [{ "id" => "P-3" }], "next_cursor" => "c3" },
    "c3" => { "data" => [{ "id" => "P-4" }], "next_cursor" => nil }
  }.freeze

  def setup
    super
    server.respond do |request|
      cursor = request.query.to_s[/cursor=([^&]+)/, 1]
      MockServer.json(PAGES.fetch(cursor))
    end
    @proposals = client(company_id: "co_1").proposals
  end

  def test_page_is_typed
    page = @proposals.list(limit: 2)

    assert_instance_of Tungo::Page, page
    assert_instance_of Tungo::Models::ProposalListItem, page.data.first
    assert_equal %w[P-1 P-2], page.map(&:id)
    assert_equal "c2", page.next_cursor
    assert_predicate page, :next_page?
    assert_equal 200, page.api_response.status
    assert_kind_of Tungo::Model, page.body
  end

  def test_next_page_keeps_the_other_parameters
    page = @proposals.list(limit: 2, status: "previewed").next_page

    assert_equal %w[P-3], page.data.map(&:id)
    assert_equal "cursor=c2&limit=2&status=previewed", server.requests.last.query
    last = page.next_page

    refute_predicate last, :next_page?
    assert_raises(Tungo::PaginationError) { last.next_page }
  end

  def test_list_all_is_lazy
    all = @proposals.list_all(limit: 2)

    assert_instance_of Enumerator, all
    assert_empty server.requests
    assert_equal %w[P-1 P-2], all.first(2).map(&:id)
    assert_equal 1, server.requests.size
    assert_equal %w[P-1 P-2 P-3], all.lazy.map(&:id).first(3)
  end

  def test_list_all_walks_every_page
    assert_equal %w[P-1 P-2 P-3 P-4], @proposals.list_all.map(&:id)
    assert_equal [nil, "cursor=c2", "cursor=c3"], server.requests.map(&:query)
  end

  def test_auto_paging_each_from_a_page
    assert_equal %w[P-1 P-2 P-3 P-4], @proposals.list.auto_paging_each.map(&:id)
  end

  def test_repeated_cursor_raises_instead_of_looping
    server.respond { |_| MockServer.json({ "data" => [{ "id" => "P-1" }], "next_cursor" => "same" }) }
    error = assert_raises(Tungo::PaginationError) { @proposals.list_all.take(50) }

    assert_match(/twice/, error.message)
    assert_equal 2, server.requests.size
  end

  def test_empty_and_missing_data
    server.respond { |_| MockServer.json({ "next_cursor" => "" }) }
    page = @proposals.list

    assert_empty page.data
    refute_predicate page, :next_page?
    assert_empty @proposals.list_all.to_a
  end

  def test_errors_surface_from_the_enumerator
    server.respond { |_, count| count == 1 ? MockServer.json(PAGES[nil]) : MockServer.error(403, "permission_error") }

    assert_raises(Tungo::PermissionError) { @proposals.list_all.to_a }
  end
end
