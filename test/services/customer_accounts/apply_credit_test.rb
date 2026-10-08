require "test_helper"
require_relative "../../support/customer_account_helpers"

class CustomerAccounts::ApplyCreditTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  def setup
    setup_account
  end

  def apply(allocations, customer: @customer)
    CustomerAccounts::ApplyCredit.call(customer: customer, user: @admin, allocations: allocations)
  end

  test "deuda $250.000 y transferencia $300.000: $250.000 aplicados y $50.000 de saldo a favor" do
    make_order(150, delivery_date: Date.new(2026, 10, 5))
    make_order(100, delivery_date: Date.new(2026, 10, 6))
    result = register(300_000)

    assert_equal pesos(50_000), result.credit_cents
    summary = CustomerAccounts::Summary.new(@customer)
    assert_equal 0, summary.pending_cents
    assert_equal pesos(50_000), summary.credit_cents
    assert_equal(-pesos(50_000), summary.account_balance_cents, "saldo de la cuenta: deuda 0 menos crédito")
  end

  test "el saldo a favor se aplica después a un pedido nuevo, solo con la acción explícita" do
    register(50_000) # sin deuda: todo queda como crédito
    new_order = make_order(30)

    assert_equal 0, new_order.reload.amount_paid_cents, "crear un pedido NO consume el crédito"
    assert_equal pesos(50_000), CustomerAccounts::ApplyCredit.available_cents(@customer)

    result = apply({ new_order.id => pesos(30_000) })

    assert result.ok?
    assert_equal pesos(30_000), new_order.reload.amount_paid_cents
    assert_equal "paid", new_order.payment_status
    assert_equal pesos(20_000), result.credit_cents
    assert_equal pesos(20_000), CustomerAccounts::ApplyCredit.available_cents(@customer)
    application = result.payments.first
    assert_equal "credit", application.application_kind
    assert_equal CustomerPayment.first.id, application.customer_payment_id, "queda ligado al pago de origen"
    assert_equal @admin, application.user
  end

  test "el mismo crédito no se puede usar dos veces" do
    register(50_000)
    a = make_order(40)
    b = make_order(40)

    first = apply({ a.id => pesos(40_000) })
    second = apply({ b.id => pesos(40_000) })

    assert first.ok?
    assert_not second.ok?
    assert_match(/saldo a favor disponible es \$10\.000/, second.errors.join)
    assert_equal 0, b.reload.amount_paid_cents
    assert_equal pesos(10_000), CustomerAccounts::ApplyCredit.available_cents(@customer)

    assert apply({ b.id => pesos(10_000) }).ok?
    assert_equal 0, CustomerAccounts::ApplyCredit.available_cents(@customer)
    assert_not apply({ b.id => pesos(1_000) }).ok?, "con el crédito agotado no se aplica nada"
  end

  test "no se puede aplicar más que el saldo del pedido, a cancelados ni a pedidos de otro cliente" do
    register(500_000)
    order = make_order(10)
    canceled = make_order(10, status: "canceled")
    foreign = make_order(10, customer: @other_customer)

    assert_not apply({ order.id => pesos(10_001) }).ok?
    assert_not apply({ canceled.id => pesos(1_000) }).ok?
    assert_not apply({ foreign.id => pesos(1_000) }).ok?
    assert_not apply({}).ok?
    assert_not apply({ order.id => -5 }).ok?
    assert_equal pesos(500_000), CustomerAccounts::ApplyCredit.available_cents(@customer)
  end

  test "el crédito de varios pagos se usa del más antiguo al más nuevo y cada aplicación queda ligada a su origen" do
    old_payment = register(10_000, paid_on: Date.current - 10).customer_payment
    new_payment = register(10_000, paid_on: Date.current - 1).customer_payment
    order = make_order(15)

    result = apply({ order.id => pesos(15_000) })

    assert result.ok?
    by_source = result.payments.group_by(&:customer_payment_id).transform_values { |ps| ps.sum(&:amount_cents) }
    assert_equal({ old_payment.id => pesos(10_000), new_payment.id => pesos(5_000) }, by_source)
    assert_equal 0, old_payment.reload.unapplied_cents
    assert_equal pesos(5_000), new_payment.reload.unapplied_cents
  end

  test "no consume crédito de un pago anulado ni de otro cliente" do
    other = register(10_000, customer: @other_customer)
    assert other.ok?
    voided = register(10_000).customer_payment
    CustomerAccounts::VoidPayment.call(customer_payment: voided, user: @admin, reason: "error")
    order = make_order(10)

    assert_equal 0, CustomerAccounts::ApplyCredit.available_cents(@customer)
    assert_not apply({ order.id => pesos(10_000) }).ok?
    assert_equal pesos(10_000), CustomerAccounts::ApplyCredit.available_cents(@other_customer)
  end
end
