require "test_helper"
require_relative "../../support/customer_account_helpers"

class CustomerAccounts::MoneyAndDistributionTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  def setup
    setup_account
  end

  test "parse_pesos entiende importes en pesos sin floats" do
    parse = ->(text) { CustomerAccounts::Money.parse_pesos(text) }
    assert_equal 30_000_000, parse.("300000")
    assert_equal 30_000_000, parse.("300.000")
    assert_equal 30_000_000, parse.("$ 300.000")
    assert_equal 30_000_000, parse.("300,000")
    assert_equal 150_050, parse.("1.500,50")
    assert_equal 150_050, parse.("1500.50")
    assert_equal 150_000, parse.("1500,0")
    assert_equal 5, parse.("0,05")
  end

  test "parse_pesos rechaza lo ambiguo o inválido en vez de adivinar" do
    ["", "  ", "abc", "12a", "1.2.3", "1,2,3", "--5", "-100", "1e5", "1.5.000,10", "300.00.0"].each do |text|
      assert_nil CustomerAccounts::Money.parse_pesos(text), "#{text.inspect} debería ser inválido"
    end
  end

  test "format_pesos formatea con puntos y coma decimal" do
    assert_equal "300.000", CustomerAccounts::Money.format_pesos(30_000_000)
    assert_equal "1.500,50", CustomerAccounts::Money.format_pesos(150_050)
    assert_equal "0", CustomerAccounts::Money.format_pesos(0)
    assert_equal "-1.000", CustomerAccounts::Money.format_pesos(-100_000)
  end

  test "ejemplo del enunciado: $300.000 sobre $120.000 / $95.000 / $180.000 -> 120 / 95 / 85" do
    a, b, c = honey_orders
    suggestion = CustomerAccounts::Distribution.suggest(CustomerAccounts::Distribution.pending_orders(@customer).to_a, pesos(300_000))

    assert_equal({ a.id => pesos(120_000), b.id => pesos(95_000), c.id => pesos(85_000) }, suggestion.allocations)
    assert_equal 0, suggestion.unapplied_cents
  end

  test "criterio: fecha de entrega más antigua primero; a igual fecha, el creado primero" do
    later = make_order(10, delivery_date: Date.new(2026, 10, 20))
    first_created = make_order(10, delivery_date: Date.new(2026, 10, 10))
    second_created = make_order(10, delivery_date: Date.new(2026, 10, 10))
    first_created.update_columns(created_at: 2.hours.ago)
    second_created.update_columns(created_at: 1.hour.ago)

    order = CustomerAccounts::Distribution.pending_orders(@customer).to_a
    assert_equal [first_created.id, second_created.id, later.id], order.map(&:id)

    assert_equal({ first_created.id => pesos(10_000), second_created.id => pesos(5_000) }, CustomerAccounts::Distribution.suggest(order, pesos(15_000)).allocations)
  end

  test "nunca asigna más que el saldo de un pedido, ni a cancelados, ni importes negativos o cero" do
    a = make_order(10, delivery_date: Date.new(2026, 10, 5))
    canceled = make_order(50, delivery_date: Date.new(2026, 10, 6), status: "canceled")
    a.payments.create!(amount_cents: pesos(4_000), paid_at: Time.current, payment_method: "cash_on_delivery")

    pending = CustomerAccounts::Distribution.pending_orders(@customer).to_a
    assert_equal [a.id], pending.map(&:id), "el cancelado no es deuda"
    suggestion = CustomerAccounts::Distribution.suggest(pending, pesos(100_000))
    assert_equal({ a.id => pesos(6_000) }, suggestion.allocations, "solo el saldo de $6.000")
    assert_equal pesos(94_000), suggestion.unapplied_cents
    assert_not_includes suggestion.allocations.keys, canceled.id

    assert_equal({}, CustomerAccounts::Distribution.suggest(pending, 0).allocations)
    assert_equal({}, CustomerAccounts::Distribution.suggest(pending, -500).allocations)
  end

  test "los pedidos totalmente pagados y los de otros clientes no se proponen" do
    paid = make_order(10)
    paid.payments.create!(amount_cents: paid.total_cents, paid_at: Time.current, payment_method: "cash_on_delivery")
    make_order(10, customer: @other_customer)

    assert_equal [], CustomerAccounts::Distribution.pending_orders(@customer).to_a
  end
end
