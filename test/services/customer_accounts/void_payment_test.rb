require "test_helper"
require_relative "../../support/customer_account_helpers"

class CustomerAccounts::VoidPaymentTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  def setup
    setup_account
  end

  def void(payment, reason: "Cargado por error")
    CustomerAccounts::VoidPayment.call(customer_payment: payment, user: @admin, reason: reason)
  end

  test "anular conserva el registro, revierte las aplicaciones y restablece los saldos" do
    a, b, c = honey_orders
    payment = register(300_000).customer_payment
    assert_equal [0, 0, pesos(95_000)], balances(a, b, c)

    result = void(payment)

    assert result.ok?
    payment.reload
    assert payment.voided?
    assert_equal @admin, payment.voided_by
    assert_equal "Cargado por error", payment.void_reason
    assert_equal [pesos(120_000), pesos(95_000), pesos(180_000)], balances(a, b, c)
    assert_equal %w[pending pending pending], [a, b, c].map { |o| o.reload.payment_status }
    assert_equal 1, CustomerPayment.count, "el registro histórico se conserva"
    assert_equal 3, payment.applications.count, "las aplicaciones también se conservan, anuladas"
    assert payment.applications.all?(&:voided?)
    assert_equal 0, payment.applications.active.count
  end

  test "revierte el saldo a favor no utilizado: el crédito del pago anulado desaparece" do
    make_order(40)
    payment = register(100_000).customer_payment
    assert_equal pesos(60_000), CustomerAccounts::ApplyCredit.available_cents(@customer)

    assert void(payment).ok?
    assert_equal 0, CustomerAccounts::ApplyCredit.available_cents(@customer)
    assert_equal 0, CustomerAccounts::Summary.new(@customer).received_cents, "ya no cuenta como ingreso"
  end

  test "el motivo es obligatorio y no se anula dos veces" do
    make_order(10)
    payment = register(10_000).customer_payment

    assert_not void(payment, reason: "  ").ok?
    assert_not payment.reload.voided?

    assert void(payment).ok?
    second = void(payment)
    assert_not second.ok?
    assert_match(/ya está anulado/, second.errors.join)
  end

  test "si parte del crédito ya se aplicó a pedidos posteriores, la anulación se bloquea y explica por qué" do
    payment = register(50_000).customer_payment
    later = make_order(30)
    CustomerAccounts::ApplyCredit.call(customer: @customer, user: @admin, allocations: { later.id => pesos(30_000) })

    result = void(payment)

    assert_not result.ok?
    assert_match(/ya se aplicó a pedidos posteriores/, result.errors.join)
    assert_match(/#{later.number}/, result.errors.join)
    assert_not payment.reload.voided?
    assert_equal pesos(30_000), later.reload.amount_paid_cents, "nada se modificó por detrás"
  end

  test "revirtiendo primero la aplicación de saldo a favor, la anulación del pago ya es posible" do
    payment = register(50_000).customer_payment
    later = make_order(30)
    application = CustomerAccounts::ApplyCredit.call(customer: @customer, user: @admin, allocations: { later.id => pesos(30_000) }).payments.first

    revert = CustomerAccounts::RevertCreditApplication.call(payment: application, user: @admin, reason: "Pedido equivocado")
    assert revert.ok?
    assert application.reload.voided?
    assert_equal "Pedido equivocado", application.void_reason
    assert_equal 0, later.reload.amount_paid_cents, "el saldo del pedido se restablece"
    assert_equal pesos(50_000), CustomerAccounts::ApplyCredit.available_cents(@customer), "el importe vuelve al saldo a favor"

    assert void(payment).ok?
    assert_equal 0, CustomerAccounts::ApplyCredit.available_cents(@customer)
  end

  test "revertir una aplicación exige motivo, solo aplica a aplicaciones de saldo a favor y no se repite" do
    order = make_order(10)
    distribution = register(10_000).payments.first
    assert_not CustomerAccounts::RevertCreditApplication.call(payment: distribution, user: @admin, reason: "x").ok?

    payment = register(10_000).customer_payment
    other = make_order(10)
    application = CustomerAccounts::ApplyCredit.call(customer: @customer, user: @admin, allocations: { other.id => pesos(10_000) }).payments.first
    assert_not CustomerAccounts::RevertCreditApplication.call(payment: application, user: @admin, reason: "").ok?
    assert CustomerAccounts::RevertCreditApplication.call(payment: application, user: @admin, reason: "ok").ok?
    assert_not CustomerAccounts::RevertCreditApplication.call(payment: application, user: @admin, reason: "otra vez").ok?
    assert_equal 0, order.reload.balance_due_cents, "el pago original no se tocó"
    assert payment.reload.applications.active.none?
  end

  test "una aplicación de cuenta corriente no se puede borrar suelta; el pago individual sí" do
    order = make_order(20)
    individual = order.payments.create!(amount_cents: pesos(5_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    application = register(15_000).payments.first

    assert_not application.destroy
    assert_match(/anulalo desde la cuenta corriente/, application.errors.full_messages.join)
    assert Payment.exists?(application.id)
    assert_equal pesos(20_000), order.reload.amount_paid_cents

    assert individual.destroy, "los pagos por pedido se borran como siempre"
    assert_equal pesos(15_000), order.reload.amount_paid_cents
  end

  test "un pedido con aplicaciones de cuenta corriente no puede cambiar de cliente" do
    order = make_order(10)
    register(10_000)

    order.customer = @other_customer
    assert_not order.save
    assert_match(/No se puede cambiar el cliente/, order.errors.full_messages.join)
    assert_equal @customer.id, order.reload.customer_id

    # sin pagos de cuenta corriente (o con pagos individuales) el cambio sigue permitido
    free = make_order(10)
    free.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")
    free.customer = @other_customer
    assert free.save
  end

  test "borrar un pedido sigue funcionando (las aplicaciones se borran con él)" do
    order = make_order(10)
    register(10_000)

    assert_nothing_raised { order.destroy! }
  end
end
