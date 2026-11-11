# frozen_string_literal: true

require_relative "test_helper"

class ModelsTest < TungoTestCase
  Models = Tungo::Models

  def money
    Models::Money.from_wire({ "amount" => 1234.5, "amount_tiyn" => 123_450, "formatted" => "1 234,50 ₸", "new" => [1] })
  end

  def test_every_contract_type_has_a_model
    names = Dir[File.join(ROOT, "lib/tungo/models/*.rb")].map { |file| File.basename(file, ".rb") }

    assert_operator names.size, :>, 400
    assert_equal names.size, Models.constants.size
    Models.constants.each do |name|
      const = Models.const_get(name)

      assert(const.is_a?(Class) ? const < Tungo::Model : const.respond_to?(:coerce), name.to_s)
    end
  end

  def test_inspect_hides_credentials
    secret = Models::WebhookSecret.from_wire({ "endpoint_id" => "ep_1", "secret" => "whsec_TOPSECRET" })

    [secret.inspect, secret.to_s, [secret].inspect].each do |text|
      refute_includes text, "TOPSECRET"
      assert_includes text, "endpoint_id=\"ep_1\" secret=[REDACTED]"
    end
    # The value itself stays readable, and serialisation still carries it.
    assert_equal "whsec_TOPSECRET", secret.secret
    assert_includes secret.to_json, "whsec_TOPSECRET"
  end

  def test_typed_readers_and_unknown_fields
    assert_equal 123_450, money.amount_tiyn
    assert_equal "1 234,50 ₸", money.formatted
    assert_equal [1], money[:new]
    assert_equal [1], money["new"]
    assert money.key?(:new)
    refute money.key?(:other)
    assert_nil money[:other]
  end

  def test_models_are_immutable
    assert_predicate money, :frozen?
    assert_predicate money.formatted, :frozen?
    assert_predicate money[:new], :frozen?
    refute_respond_to money, :amount_tiyn=
    assert_raises(FrozenError) { money.instance_variable_set(:@data, {}) }
  end

  def test_with_returns_a_changed_copy
    changed = money.with(amount_tiyn: 1)

    assert_equal 1, changed.amount_tiyn
    assert_equal 123_450, money.amount_tiyn
    assert_equal [1], changed[:new]
  end

  def test_round_trip
    assert_equal({ "amount" => 1234.5, "amount_tiyn" => 123_450, "formatted" => "1 234,50 ₸", "new" => [1] },
                 money.to_wire)
    assert_equal({ amount: 1234.5, amount_tiyn: 123_450, formatted: "1 234,50 ₸", new: [1] }, money.to_h)
    assert_equal money.to_wire, JSON.parse(money.to_json)
    assert_equal money.to_wire, JSON.parse(JSON.generate("total" => money))["total"]
  end

  def test_equality_and_pattern_matching
    assert_equal money, Models::Money.from_wire(money.to_wire)
    assert_equal money.hash, Models::Money.from_wire(money.to_wire).hash
    refute_equal money, money.with(amount_tiyn: 2)
    matched = case money
              in { amount_tiyn: Integer => tiyn } then tiyn
              end

    assert_equal 123_450, matched
  end

  def test_construction_with_keywords
    built = Models::Money.new(amount: 1, amount_tiyn: 100, formatted: "1,00 ₸")

    assert_equal 100, built.amount_tiyn
    assert_equal({ "amount" => 1, "amount_tiyn" => 100, "formatted" => "1,00 ₸" }, built.to_wire)
  end

  def test_nested_models_arrays_and_null
    item = Models::ProposalListItem.from_wire(
      { "id" => "P-1", "total" => { "amount" => 1, "amount_tiyn" => 100, "formatted" => "1,00 ₸" }, "title" => nil }
    )

    assert_instance_of Models::Money, item.total
    assert_nil item.title
    assert item.key?(:title)
    assert_equal({ "amount" => 1, "amount_tiyn" => 100, "formatted" => "1,00 ₸" }, item.to_wire["total"])
    assert_equal 100, item.to_h[:total][:amount_tiyn]
    list = Models::ChatTurnResult.from_wire({ "errors" => [{ "type" => "limit_error", "message" => "m" }] })

    assert_instance_of Models::ChatTurnError, list.errors.first
    assert_predicate list.errors, :frozen?
  end

  def test_wrong_shapes_do_not_raise
    odd = Models::ProposalListItem.from_wire({ "id" => 5, "total" => "many", "extra" => { "a" => 1 } })

    assert_equal 5, odd.id
    assert_equal "many", odd.total
    assert_equal({ "a" => 1 }, odd[:extra])
  end

  def test_reserved_property_names_get_an_underscore
    action = Models::ProposalAction.from_wire({ "method" => "POST" })

    assert_equal "POST", action.method_
    assert_equal "POST", action[:method]
    assert_equal({ "method" => "POST" }, action.with(method_: "POST").to_wire)
    assert_equal :to_s, action.method(:to_s).name
  end

  def test_enums_are_constants_and_unknown_safe
    status = Models::ProposalStatus

    assert_equal "previewed", status::PREVIEWED
    assert_includes status.values, "approved"
    assert status.known?("approved")
    assert status.known?(:approved)
    refute status.known?("brand_new")
    item = Models::ProposalListItem.from_wire({ "status" => "brand_new" })

    assert_equal "brand_new", item.status
  end

  def test_discriminated_union
    event = Models::ChatEvent.coerce({ "type" => "text", "delta" => "Hi" })

    assert_instance_of Models::ChatEventText, event
    assert_equal "Hi", event.delta
    assert_equal "type", Models::ChatEvent.discriminator
    assert_equal Models::ChatEventDone, Models::ChatEvent.mapping.fetch("done")
  end

  def test_union_with_an_unknown_discriminator
    unknown = Models::WebhookEvent.coerce({ "type" => "galaxy.created", "data" => { "id" => 1 } })

    assert_instance_of Tungo::UnknownVariant, unknown
    assert_equal "galaxy.created", unknown[:type]
    assert_equal({ "type" => "galaxy.created", "data" => { "id" => 1 } }, unknown.to_wire)
    assert_instance_of Tungo::UnknownVariant, Models::ChatEvent.coerce({ "no_type" => true })
  end

  def test_union_without_a_discriminator
    file = Models::IsnaFile.required_api_names.to_h { |name| [name, "x"] }

    assert_instance_of Models::IsnaFile, Models::IsnaResponse.coerce(file)
    assert_instance_of Tungo::UnknownVariant, Models::IsnaResponse.coerce({ "nothing" => 1 }) \
      unless [Models::IsnaFile, Models::IsnaSummary].any? { |klass| klass.required_api_names.empty? }
    assert_equal "text", Models::IsnaResponse.coerce("text")
  end

  def test_alias_types
    spec = Models::AutomationOutputSpec.coerce({ "total" => { "type" => "number" } })

    assert_kind_of Hash, spec
    assert_kind_of Tungo::Model, spec.fetch("total")
  end

  def test_results_carry_the_response
    server.respond { |_| MockServer.json({ "data" => [{ "id" => "co_1", "name" => "ТОО Ромашка" }] }) }
    list = client.companies.list

    assert_instance_of Models::ListCompaniesResponse, list
    assert_equal 200, list.api_response.status
    assert_equal "ТОО Ромашка", list.data.first.name
    assert_nil list.data.first.api_response
  end

  def test_money_never_passes_through_a_binary_float
    body = '{"data":[{"id":"P-1","total":{"amount":90071992547409.93,"amount_tiyn":9007199254740993,' \
           '"formatted":"x"},"vat":{"amount":0.1,"amount_tiyn":10,"formatted":"y"}}],"next_cursor":null}'
    server.respond { |_| { status: 200, headers: { "content-type" => "application/json" }, body: body } }
    item = client(company_id: "co_1").proposals.list.data.first

    assert_instance_of BigDecimal, item.total.amount
    assert_equal BigDecimal("90071992547409.93"), item.total.amount
    assert_equal 9_007_199_254_740_993, item.total.amount_tiyn
    assert_equal BigDecimal("0.1"), item.vat.amount
    assert_equal BigDecimal("0.3"), item.vat.amount * 3
    assert_includes item.to_json, '"amount":90071992547409.93'
    assert_includes JSON.generate({ "item" => item }), '"amount":0.1,'
    assert_equal 9_007_199_254_740_993, Tungo::Money.to_tiyn(item.total.amount)
  end

  def test_decimals_are_sent_exactly
    client(company_id: "co_1").batches.create_bank_statement(file: "eA==", limit: BigDecimal("12.50"))

    assert_includes server.requests.last.body, '"limit":12.5'
    assert_raises(Tungo::ValidationError) do
      client(company_id: "co_1").batches.create_bank_statement(file: "eA==", limit: BigDecimal("NaN"))
    end
  end

  def test_inspect_is_readable
    assert_match(/\A#<Tungo::Models::Money amount=1234.5 amount_tiyn=123450/, money.inspect)
  end
end
