require "test_helper"
require_relative "../../support/customer_account_helpers"

# Cuenta corriente en Admin → Clientes: pantalla, formulario de pago global con
# distribución, saldo a favor, anulación, permisos e historial.
class Admin::CustomerAccountsTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include CustomerAccountHelpers

  setup do
    setup_account
    @cook = User.create!(email: "acct-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "acct-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: @other_customer)
    sign_in @admin
  end

  def payment_params(amount, allocations: {}, **extra)
    { amount: amount, paid_on: Date.current.iso8601, payment_method: "bank_transfer", reference: "TRF-1", note: "semanal", allocations: allocations.transform_keys(&:to_s), request_token: SecureRandom.uuid }.merge(extra)
  end

  # --- Acceso y navegación -----------------------------------------------------------

  test "Admin → Clientes tiene el botón Cuenta corriente (listado y ficha)" do
    get admin_customers_path
    assert_select "a[href=?]", admin_customer_account_path(@customer), text: "Cuenta corriente"

    get admin_customer_path(@customer)
    assert_select "a[href=?]", admin_customer_account_path(@customer), text: "Cuenta corriente"
  end

  test "permisos: solo admin entra a la cuenta corriente y a sus acciones; production, clientes y visitantes no" do
    order = make_order(10)
    payment = register(10_000).customer_payment
    targets = [
      [:get, admin_customer_account_path(@customer)],
      [:get, new_admin_customer_customer_payment_path(@customer)],
      [:post, admin_customer_customer_payments_path(@customer), payment_params("1.000")],
      [:post, void_admin_customer_customer_payment_path(@customer, payment), { reason: "x" }],
      [:get, new_admin_customer_credit_application_path(@customer)],
      [:post, admin_customer_credit_applications_path(@customer), { allocations: { order.id => "1" } }]
    ]
    before = [CustomerPayment.count, Payment.count, payment.reload.voided?]

    [@cook, @customer_user].each do |user|
      sign_out :user
      sign_in user
      targets.each do |verb, path, params|
        send(verb, path, params: params)
        assert_response :redirect, "#{user.role} no debería poder #{verb} #{path}"
        assert_no_match(/#{Regexp.escape(@customer.name)}/, response.body)
      end
    end

    sign_out :user
    targets.each do |verb, path, params|
      send(verb, path, params: params)
      assert_redirected_to new_user_session_path
    end
    assert_equal before, [CustomerPayment.count, Payment.count, payment.reload.voided?]
  end

  test "un cliente no puede ver la cuenta corriente de otro (ni la propia): no hay endpoint público" do
    sign_out :user
    sign_in @customer_user

    get admin_customer_account_path(@other_customer)
    assert_response :redirect
    get admin_customer_account_path(@customer)
    assert_response :redirect
  end

  # --- Pantalla ----------------------------------------------------------------------------

  test "muestra el resumen, la tabla de pedidos ordenada por entrega y el historial" do
    a, b, c = honey_orders
    c.payments.create!(amount_cents: pesos(10_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    register(100_000)

    get admin_customer_account_path(@customer)

    assert_response :success
    assert_select "h1", text: "Cuenta corriente"
    assert_match @customer.name, response.body
    assert_select "#account-orders-count", text: "3"
    assert_select "#account-invoiced", text: "$395.000"
    assert_select "#account-applied", text: "$110.000"
    assert_select "#account-pending", text: "$285.000"
    assert_select "#account-credit", text: "$0"
    assert_select "#account-received", text: "$110.000"
    assert_select "a#register-payment", text: "+ Registrar pago"
    numbers = css_select("#account-orders tbody tr td:first-child").map { |td| td.text.strip }
    assert_equal [a.number, b.number, c.number], numbers
    assert_select "#account-orders a[href=?]", admin_order_path(a), text: "Ver pedido"
    assert_select "#account-history .account-payment", count: 2
  end

  test "el historial no cuenta dos veces: cada pago global aparece una vez con su distribución dentro" do
    honey_orders
    register(300_000)

    get admin_customer_account_path(@customer)

    assert_select "#account-history .account-payment", count: 1
    assert_select "#account-history .account-payment--global li", count: 3
    assert_select "#account-history .account-payment", text: /\$300\.000/
    assert_select "#account-received", text: "$300.000"
  end

  test "historial: fecha, monto, medio, referencia, comentario, usuario y distribución" do
    make_order(10)
    register(10_000, reference: "TRF-777", note: "Pago semanal", method: "cash_on_delivery")
    legacy = make_order(5).payments.create!(amount_cents: pesos(2_000), paid_at: Time.current, payment_method: "bank_transfer")

    get admin_customer_account_path(@customer)

    assert_select ".account-payment--global", text: /Efectivo contraentrega/
    assert_select ".account-payment--global", text: /Ref: TRF-777/
    assert_select ".account-payment--global", text: /Comentario: Pago semanal/
    assert_select ".account-payment--global", text: /Registrado por #{Regexp.escape(@admin.email)}/
    assert_select ".account-payment--individual#payment-#{legacy.id}", text: /Usuario no registrado/, count: 1
  end

  test "filtros de pedidos: pendientes, pagados y rango de fechas" do
    a, b, c = honey_orders
    register(120_000)

    get admin_customer_account_path(@customer, filter: "pending")
    assert_equal [b.number, c.number], css_select("#account-orders tbody tr td:first-child").map { |td| td.text.strip }

    get admin_customer_account_path(@customer, filter: "paid")
    assert_equal [a.number], css_select("#account-orders tbody tr td:first-child").map { |td| td.text.strip }

    get admin_customer_account_path(@customer, from: "2026-10-07", to: "2026-10-07")
    assert_equal [c.number], css_select("#account-orders tbody tr td:first-child").map { |td| td.text.strip }

    get admin_customer_account_path(@customer, from: "basura", filter: "<script>")
    assert_response :success
    assert_match "Alguna fecha no era válida", response.body
  end

  test "los pedidos cancelados no figuran como deuda y se avisa de lo pagado sobre ellos" do
    kept = make_order(10)
    canceled = make_order(20)
    canceled.payments.create!(amount_cents: pesos(5_000), paid_at: Time.current, payment_method: "cash_on_delivery")
    canceled.update!(status: "canceled")

    get admin_customer_account_path(@customer)

    assert_select "#account-pending", text: "$10.000"
    assert_select "#account-orders-count", text: "1"
    assert_select "#account-canceled-paid", text: /\$5\.000 pagados sobre pedidos cancelados/
    assert_no_match(/#{canceled.number}.*Ver pedido/m, css_select("#account-orders").to_s)
  end

  # --- Formulario y registro -----------------------------------------------------------

  test "el formulario trae cliente, fecha, importe, medio, referencia, comentario y los pedidos pendientes ordenados" do
    a, b, c = honey_orders
    make_order(10, status: "canceled")

    get new_admin_customer_customer_payment_path(@customer)

    assert_response :success
    assert_match @customer.name, response.body
    assert_select "input[name=amount]"
    assert_select "input[name=paid_on][value=?]", Date.current.iso8601
    assert_select "select[name=payment_method] option", minimum: 3
    assert_select "input[name=reference]"
    assert_select "input[name=note]"
    assert_select "input[name=request_token][value]"
    assert_equal [a.id, b.id, c.id].map(&:to_s), css_select("tr[data-payment-distribution-target=row]").map { |tr| tr["data-order-id"] }
    assert_select "input[name^='allocations[']", count: 3
    assert_select "#payment-preview"
    assert_match "Monto recibido − Monto distribuido = Saldo sin aplicar", response.body
    assert_select "[data-controller=payment-distribution]"
  end

  test "registra un pago global repartido y vuelve a la cuenta corriente con el resultado" do
    a, b, c = honey_orders
    params = payment_params("300.000", allocations: { a.id => "120.000", b.id => "95.000", c.id => "85.000" })

    assert_difference "CustomerPayment.count", 1 do
      assert_difference "Payment.count", 3 do
        post admin_customer_customer_payments_path(@customer), params: params
      end
    end

    assert_redirected_to admin_customer_account_path(@customer)
    assert_equal [0, 0, pesos(95_000)], balances(a, b, c)
    payment = CustomerPayment.last
    assert_equal @admin, payment.user
    assert_equal "TRF-1", payment.reference
    follow_redirect!
    assert_match "Pago registrado", response.body
    assert_select "#account-pending", text: "$95.000"
  end

  test "un excedente queda como saldo a favor y se informa" do
    a = make_order(250)

    post admin_customer_customer_payments_path(@customer), params: payment_params("300000", allocations: { a.id => "250.000" })

    assert_redirected_to admin_customer_account_path(@customer)
    follow_redirect!
    assert_match "Quedaron $50.000 como saldo a favor", response.body
    assert_select "#account-credit", text: "$50.000"
    assert_select "a#apply-credit"
  end

  test "montos inválidos se rechazan con el formulario relleno y sin escribir nada" do
    a = make_order(100)
    [
      payment_params("abc", allocations: { a.id => "1" }),
      payment_params("", allocations: { a.id => "1" }),
      payment_params("0"),
      payment_params("100.000", allocations: { a.id => "100.001" }),
      payment_params("100.000", allocations: { a.id => "-5" }),
      payment_params("50.000", allocations: { a.id => "60.000" }),
      payment_params("100.000", allocations: { a.id => "uno" }),
      payment_params("100.000", paid_on: "no-es-fecha"),
      payment_params("100.000", payment_method: "bitcoin")
    ].each do |params|
      post admin_customer_customer_payments_path(@customer), params: params
      assert_response :unprocessable_entity, "debería rechazar #{params.inspect}"
      assert_select "#payment-errors"
    end

    assert_equal 0, CustomerPayment.count
    assert_equal 0, Payment.count
    post admin_customer_customer_payments_path(@customer), params: payment_params("100.000", allocations: { a.id => "70.000" }, reference: "REF-RELLENO")
    assert_response :redirect
    post admin_customer_customer_payments_path(@customer), params: payment_params("abc", reference: "REF-RELLENO")
    assert_select "input[name=reference][value=?]", "REF-RELLENO"
  end

  test "no acepta pedidos de otro cliente por manipulación de parámetros" do
    foreign = make_order(10, customer: @other_customer)

    post admin_customer_customer_payments_path(@customer), params: payment_params("10.000", allocations: { foreign.id => "10.000" })

    assert_response :unprocessable_entity
    assert_match "no pertenece a este cliente", response.body
    assert_equal 0, foreign.reload.amount_paid_cents
    assert_equal 0, CustomerPayment.count
  end

  test "el reenvío del formulario (mismo token) no duplica el pago" do
    a = make_order(100)
    params = payment_params("40.000", allocations: { a.id => "40.000" })

    2.times { post admin_customer_customer_payments_path(@customer), params: params }

    assert_equal 1, CustomerPayment.count
    assert_equal pesos(40_000), a.reload.amount_paid_cents
    follow_redirect!
    assert_match "ya estaba registrado", response.body
  end

  # --- Saldo a favor y anulación -------------------------------------------------------------

  test "aplicar saldo a favor desde la pantalla" do
    register(50_000, allocations: {})
    order = make_order(30)

    get new_admin_customer_credit_application_path(@customer)
    assert_response :success
    assert_select "[data-payment-distribution-fixed-amount-value=?]", pesos(50_000).to_s
    assert_select "tr[data-order-id=?]", order.id.to_s

    post admin_customer_credit_applications_path(@customer), params: { allocations: { order.id => "30.000" } }
    assert_redirected_to admin_customer_account_path(@customer)
    follow_redirect!
    assert_match "Te quedan $20.000 de saldo a favor", response.body
    assert_equal "paid", order.reload.payment_status
    assert_select "#account-credit", text: "$20.000"
  end

  test "no se puede aplicar saldo a favor inexistente o de más" do
    order = make_order(30)
    get new_admin_customer_credit_application_path(@customer)
    assert_match "no tiene saldo a favor", response.body

    post admin_customer_credit_applications_path(@customer), params: { allocations: { order.id => "30.000" } }
    assert_response :unprocessable_entity
    assert_equal 0, order.reload.amount_paid_cents
  end

  test "anular un pago pide motivo, conserva el registro y restablece saldos" do
    a, b, c = honey_orders
    payment = register(300_000).customer_payment

    post void_admin_customer_customer_payment_path(@customer, payment), params: { reason: "" }
    assert_redirected_to admin_customer_account_path(@customer)
    assert_not payment.reload.voided?

    post void_admin_customer_customer_payment_path(@customer, payment), params: { reason: "Transferencia duplicada" }
    assert payment.reload.voided?
    assert_equal [pesos(120_000), pesos(95_000), pesos(180_000)], balances(a, b, c)
    follow_redirect!
    assert_match "Pago anulado", response.body
    assert_select ".account-payment--voided", text: /Motivo: Transferencia duplicada/
    assert_select "#account-received", text: "$0"
  end

  test "la anulación bloqueada por crédito ya aplicado se explica en pantalla" do
    payment = register(50_000, allocations: {}).customer_payment
    later = make_order(30)
    CustomerAccounts::ApplyCredit.call(customer: @customer, user: @admin, allocations: { later.id => pesos(30_000) })

    post void_admin_customer_customer_payment_path(@customer, payment), params: { reason: "error" }
    follow_redirect!

    assert_match "ya se aplicó a pedidos posteriores", response.body
    assert_not payment.reload.voided?
    assert_select "form[action=?]", revert_admin_customer_credit_application_path(@customer, Payment.find_by(application_kind: "credit"))
  end

  test "no se puede anular el pago de otro cliente a través de esta cuenta" do
    foreign_payment = register(10_000, customer: @other_customer, orders: []).customer_payment

    post void_admin_customer_customer_payment_path(@customer, foreign_payment), params: { reason: "x" }

    assert_response :not_found
    assert_not foreign_payment.reload.voided?
  end

  # --- Convivencia con los pagos por pedido ---------------------------------------------------

  test "el pago por pedido existente sigue funcionando y registra al usuario" do
    order = make_order(10)

    assert_difference "Payment.count", 1 do
      post admin_order_payments_path(order), params: { payment: { amount: "4", paid_at: Date.current, payment_method: "cash_on_delivery", note: "Seña" } }
    end

    payment = Payment.last
    assert payment.individual?
    assert_equal @admin, payment.user
    assert_equal 400, order.reload.amount_paid_cents
    get admin_customer_account_path(@customer)
    assert_select "#account-history .account-payment--individual", count: 1
    assert_select "#account-received", text: "$4"
  end

  test "en el pedido, las aplicaciones de cuenta corriente se identifican y no se pueden borrar sueltas" do
    order = make_order(10)
    register(10_000)
    application = order.payments.first

    get admin_order_path(order)
    assert_match "Pago de cuenta corriente", response.body
    assert_select "form[action=?]", admin_order_payment_path(order, application), count: 0

    assert_no_difference "Payment.count" do
      delete admin_order_payment_path(order, application)
    end
    assert_redirected_to admin_order_path(order)
    follow_redirect!
    assert_match "anulalo desde la cuenta corriente", response.body
    assert_equal pesos(10_000), order.reload.amount_paid_cents
  end

  test "un pago anulado se ve tachado en el pedido y ya no cuenta" do
    order = make_order(10)
    payment = register(10_000).customer_payment
    CustomerAccounts::VoidPayment.call(customer_payment: payment, user: @admin, reason: "error de carga")

    get admin_order_path(order)

    assert_select ".badge", text: "Anulado"
    assert_match "Motivo de la anulación", response.body
    assert_equal 0, order.reload.amount_paid_cents
  end

  test "no cambia stock, producción ni importes originales de pedidos" do
    order = make_order(100)
    totals = Order.order(:id).pluck(:id, :total_cents, :delivery_date, :status)
    stock = StockMovement.count

    register(100_000)
    post void_admin_customer_customer_payment_path(@customer, CustomerPayment.last), params: { reason: "prueba" }

    assert_equal totals, Order.order(:id).pluck(:id, :total_cents, :delivery_date, :status)
    assert_equal stock, StockMovement.count
  end
end
