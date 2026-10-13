require "test_helper"
require_relative "../../support/retail_helpers"

class Retail::PaymentsTest < ActiveSupport::TestCase
  include RetailHelpers

  setup do
    setup_retail
    @order = create_retail(items: [product_row(@mini, 10, "1.000")]) # $10.000
  end

  test "sin pagos: pendiente, saldo = total" do
    assert_equal "pending", @order.payment_status
    assert_equal pesos(10_000), @order.balance_cents
  end

  test "pago parcial y pago total, con distintos medios" do
    assert pay_retail(@order, "4.000", method: "transfer").ok?
    @order.reload
    assert_equal "partial", @order.payment_status
    assert_equal pesos(6_000), @order.balance_cents

    assert pay_retail(@order, "6.000", method: "cash_on_delivery").ok?
    @order.reload
    assert_equal "paid", @order.payment_status
    assert_equal 0, @order.balance_cents
    assert_equal %w[transfer cash_on_delivery], @order.retail_order_payments.map(&:payment_method)
  end

  test "Openpay se registra manualmente como un medio más" do
    assert pay_retail(@order, "1.000", method: "openpay").ok?
    assert_equal "Openpay", @order.retail_order_payments.first.payment_method_label
  end

  test "guarda fecha, importe, medio, observaciones y usuario" do
    result = Retail::RegisterPayment.call(order: @order, user: @admin, amount: "2.500,50", paid_at: "2026-10-10", payment_method: "transfer", notes: "Seña")
    payment = result.record

    assert_equal 250_050, payment.amount_cents
    assert_equal Date.new(2026, 10, 10), payment.paid_at
    assert_equal "Seña", payment.notes
    assert_equal @admin, payment.user
  end

  test "no permite superar el saldo sin confirmar el excedente" do
    result = pay_retail(@order, "12.000")
    assert_not result.ok?
    assert_match(/supera el saldo pendiente/, result.errors.join)
    assert_equal 0, @order.reload.amount_paid_cents

    result = pay_retail(@order, "12.000", allow_excess: "1")
    assert result.ok?
    assert result.record.excess_confirmed?
    @order.reload
    assert_equal pesos(2_000), @order.excess_cents
    assert_equal "paid", @order.payment_status
  end

  test "valida importe, fecha y medio" do
    assert_not pay_retail(@order, "0").ok?
    assert_not pay_retail(@order, "-5").ok?
    assert_not pay_retail(@order, "abc").ok?
    assert_not pay_retail(@order, "100", method: "efectivo").ok?
    assert_not Retail::RegisterPayment.call(order: @order, user: @admin, amount: "100", paid_at: "no-fecha", payment_method: "transfer").ok?
    assert_equal 0, @order.retail_order_payments.count
  end

  test "request_token evita registrar dos veces el mismo envío" do
    first = pay_retail(@order, "1.000", request_token: "tok-1")
    second = pay_retail(@order, "1.000", request_token: "tok-1")

    assert first.ok?
    assert second.duplicate?
    assert_equal 1, @order.retail_order_payments.count
    assert_equal pesos(1_000), @order.reload.amount_paid_cents
  end

  test "anular es una corrección auditable: se conserva, con motivo y usuario, y no cuenta en el saldo" do
    payment = pay_retail(@order, "10.000").record
    assert_equal "paid", @order.reload.payment_status

    assert_not Retail::VoidPayment.call(payment: payment, user: @admin, reason: " ").ok?

    result = Retail::VoidPayment.call(payment: payment, user: @admin, reason: "Se cargó dos veces")
    assert result.ok?
    payment.reload
    assert payment.voided?
    assert_equal "Se cargó dos veces", payment.void_reason
    assert_equal @admin, payment.voided_by
    @order.reload
    assert_equal 0, @order.amount_paid_cents
    assert_equal "pending", @order.payment_status
    assert_equal 1, @order.retail_order_payments.count, "el registro no se borra"
    assert_not Retail::VoidPayment.call(payment: payment, user: @admin, reason: "otra vez").ok?
  end

  test "un pago nunca se borra" do
    payment = pay_retail(@order, "1.000").record

    assert_not payment.destroy
    assert_not @order.destroy
    assert_equal 1, RetailOrderPayment.count
  end

  test "no admite pagos nuevos en pedidos cancelados, pero conserva los existentes" do
    pay_retail(@order, "3.000")
    Retail::ChangeStatus.call(order: @order, to_status: "canceled", user: @admin)

    assert_not pay_retail(@order.reload, "100").ok?
    assert_equal pesos(3_000), @order.reload.amount_paid_cents
  end

  test "pedido entregado puede tener saldo pendiente" do
    Retail::ChangeStatus.call(order: @order, to_status: "delivered", user: @admin)
    assert_equal "delivered", @order.reload.status
    assert_equal "pending", @order.payment_status
    assert_equal pesos(10_000), @order.balance_cents
  end

  test "separado del mayorista: no usa Payment, CustomerPayment ni cuenta corriente" do
    assert_no_difference ["Payment.count", "CustomerPayment.count", "Order.count"] do
      pay_retail(@order, "5.000")
    end
    assert_equal 0, @customer.orders.count
  end

  test "el estado de pago es independiente del operativo" do
    pay_retail(@order, "10.000")
    Retail::ChangeStatus.call(order: @order, to_status: "in_preparation", user: @admin)
    @order.reload
    assert_equal "in_preparation", @order.status
    assert_equal "paid", @order.payment_status
  end
end
