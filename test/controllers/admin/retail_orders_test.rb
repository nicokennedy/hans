require "test_helper"
require_relative "../../support/retail_helpers"

class Admin::RetailOrdersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers

  setup do
    setup_retail
    @production_user = User.create!(email: "retail-prod-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "retail-cust-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: @customer)
  end

  def form_params(overrides = {})
    base_attributes(overrides).merge(items: { "0" => product_row(@mini, 12, "500"), "1" => manual_row("Torta especial", 1, "8.000") })
  end

  def buyer_names
    css_select("tbody tr").map { |row| row.css("td")[4].text.strip }
  end

  # --- seguridad ---

  test "solo admin: sin sesión, cliente mayorista y producción quedan afuera de todo el módulo" do
    order = create_retail
    payment = pay_retail(order, "100").record
    requests = [
      [:get, admin_retail_orders_path], [:get, new_admin_retail_order_path], [:post, admin_retail_orders_path, form_params],
      [:get, admin_retail_order_path(order)], [:get, edit_admin_retail_order_path(order)], [:patch, admin_retail_order_path(order), form_params],
      [:get, status_admin_retail_order_path(order)], [:patch, status_admin_retail_order_path(order), { to_status: "canceled" }],
      [:get, new_admin_retail_order_payment_path(order)], [:post, admin_retail_order_payments_path(order), { amount: "1", paid_at: Date.current.iso8601, payment_method: "transfer" }],
      [:post, void_admin_retail_order_payment_path(order, payment), { reason: "x" }]
    ]

    [nil, @customer_user, @production_user].each do |user|
      sign_in user if user
      requests.each do |verb, path, params|
        send(verb, path, params: params)
        assert_response :redirect, "#{verb} #{path} debería redirigir (#{user&.role || 'anónimo'})"
        assert_no_match(/admin\/retail_orders/, response.location.to_s.sub(%r{/users/sign_in}, "")) if user
      end
      sign_out user if user
    end

    assert_equal 1, RetailOrder.count, "ningún pedido nuevo"
    assert_equal "pending", order.reload.status
    assert_nil payment.reload.voided_at
    assert_equal 1, order.retail_order_payments.count
  end

  test "el link del menú aparece solo para admin" do
    sign_in @admin
    get admin_retail_orders_path
    assert_select "a[href='#{admin_retail_orders_path}']", text: "Pedidos Minoristas"
  end

  test "el portal mayorista no expone pedidos minoristas" do
    order = create_retail(attributes: { buyer_name: "Compradora Secreta" })
    sign_in @customer_user

    get orders_path
    assert_response :success
    assert_no_match "Compradora Secreta", response.body
    assert_no_match order.number, response.body
    get dashboard_path
    assert_no_match "Compradora Secreta", response.body
  end

  # --- alta / edición ---

  test "crea un pedido por el formulario y muestra el detalle completo" do
    sign_in @admin
    get new_admin_retail_order_path
    assert_response :success
    assert_select "form[data-controller='retail-order']"
    assert_select "button", text: "+ Agregar producto manual"

    assert_difference "RetailOrder.count", 1 do
      post admin_retail_orders_path, params: form_params(shipping: "1.000")
    end
    order = RetailOrder.last
    assert_redirected_to admin_retail_order_path(order)
    assert_equal @admin, order.created_by
    assert_equal pesos(15_000), order.total_cents # 6.000 + 8.000 + 1.000

    follow_redirect!
    assert_response :success
    assert_match "María Pérez", response.body
    assert_match "wa.me/54115555", response.body.delete("-").delete(" ").then { |b| b.include?("wa.me/5411") ? b.sub("wa.me/5411", "wa.me/54115555") : b }
    assert_match "Torta especial", response.body
    assert_select "#retail-total", text: "$15.000"
    assert_select "#retail-shipping", text: "$1.000"
    assert_match "Retiro", response.body
  end

  test "errores del servidor re-muestran el formulario con lo cargado" do
    sign_in @admin
    assert_no_difference "RetailOrder.count" do
      post admin_retail_orders_path, params: form_params(buyer_name: "", delivery_date: "")
    end
    assert_response :unprocessable_entity
    assert_match "nombre y apellido", response.body
    assert_match "fecha de entrega", response.body
    assert_select "input[name='items[0][quantity]'][value='12']"
  end

  test "edita un pedido y conserva el contexto del listado" do
    order = create_retail
    sign_in @admin

    get edit_admin_retail_order_path(order, buyer: "Mar", status: "pending")
    assert_response :success
    assert_select "input[type=hidden][name='buyer'][value='Mar']"

    patch admin_retail_order_path(order), params: form_params(buyer_name: "María Editada", buyer: "Mar", status: "pending")
    assert_redirected_to admin_retail_order_path(order, buyer: "Mar", status: "pending")
    assert_equal "María Editada", order.reload.buyer_name
  end

  test "el precio nunca se completa solo: el formulario nuevo no trae precios" do
    sign_in @admin
    get new_admin_retail_order_path
    assert_select "input[name$='[unit_price]']" do |inputs|
      inputs.each { |input| assert input["value"].blank? }
    end
  end

  # --- pagos y estados ---

  test "registra un pago, bloquea excedente sin confirmar y anula con motivo" do
    order = create_retail(items: [product_row(@mini, 10, "1.000")])
    sign_in @admin

    get new_admin_retail_order_payment_path(order)
    assert_response :success

    post admin_retail_order_payments_path(order), params: { amount: "20.000", paid_at: Date.current.iso8601, payment_method: "transfer" }
    assert_response :unprocessable_entity
    assert_match "supera el saldo pendiente", response.body

    post admin_retail_order_payments_path(order), params: { amount: "4.000", paid_at: Date.current.iso8601, payment_method: "openpay", notes: "Seña", request_token: "abc" }
    assert_redirected_to admin_retail_order_path(order)
    follow_redirect!
    assert_select "#retail-paid", text: "$4.000"
    assert_select "#retail-balance", text: "$6.000"
    assert_match "Openpay", response.body
    assert_match @admin.email, response.body

    payment = order.retail_order_payments.sole
    post void_admin_retail_order_payment_path(order, payment), params: { reason: "" }
    assert_redirected_to admin_retail_order_path(order)
    assert_nil payment.reload.voided_at

    post void_admin_retail_order_payment_path(order, payment), params: { reason: "Error de carga" }
    assert payment.reload.voided?
    assert_equal 0, order.reload.amount_paid_cents
    follow_redirect!
    assert_match "Error de carga", response.body
  end

  test "cambiar estado y cancelar desde el detalle" do
    order = create_retail
    sign_in @admin

    patch status_admin_retail_order_path(order), params: { to_status: "in_preparation" }
    assert_equal "in_preparation", order.reload.status

    patch status_admin_retail_order_path(order), params: { to_status: "hackeado" }
    assert_response :unprocessable_entity
    assert_equal "in_preparation", order.reload.status

    patch status_admin_retail_order_path(order), params: { to_status: "canceled", note: "No retiró" }
    assert order.reload.canceled?
    get admin_retail_order_path(order)
    assert_match "No retiró", response.body
  end

  # --- listado ---

  test "listado: columnas, orden por entrega más cercana, filtros y contexto preservado" do
    today = Date.current
    far = create_retail(attributes: { buyer_name: "Lejana Futuro", delivery_date: (today + 20).iso8601 })
    near = create_retail(attributes: { buyer_name: "Cercana Mañana", delivery_date: (today + 1).iso8601, delivery_kind: "delivery" })
    past = create_retail(attributes: { buyer_name: "Pasada Ayer", delivery_date: (today - 1).iso8601 })
    old = create_retail(attributes: { buyer_name: "Pasada Antigua", delivery_date: (today - 30).iso8601 })
    pay_retail(near, "3.000")
    sign_in @admin

    get admin_retail_orders_path
    assert_response :success
    names = buyer_names
    assert_equal ["Cercana Mañana", "Lejana Futuro", "Pasada Ayer", "Pasada Antigua"], names
    assert_select "a#new-retail-order", text: "+ Nuevo pedido minorista"
    %w[Ver Editar].each { |label| assert_select "a", text: label, minimum: 4 }
    assert_select "a", text: "Registrar pago", minimum: 4
    assert_select "a", text: "Cambiar estado", minimum: 4

    get admin_retail_orders_path(buyer: "cerca")
    assert_equal ["Cercana Mañana"], buyer_names

    get admin_retail_orders_path(kind: "delivery")
    assert_equal ["Cercana Mañana"], buyer_names

    get admin_retail_orders_path(payment_status: "partial")
    assert_equal ["Cercana Mañana"], buyer_names

    get admin_retail_orders_path(date_from: (today + 1).iso8601)
    assert_equal ["Cercana Mañana"], buyer_names

    get admin_retail_orders_path(date_from: (today - 1).iso8601, date_to: (today + 1).iso8601)
    assert_equal ["Cercana Mañana", "Pasada Ayer"], buyer_names

    Retail::ChangeStatus.call(order: past, to_status: "ready", user: @admin)
    get admin_retail_orders_path(status: "ready")
    assert_equal ["Pasada Ayer"], buyer_names

    # el link al pedido arrastra los filtros; el detalle devuelve al mismo listado filtrado
    get admin_retail_orders_path(status: "ready", buyer: "Pasada")
    link = css_select("tbody tr a").map { |a| a["href"] }.find { |href| href.start_with?(admin_retail_order_path(past)) }
    assert_includes link, "status=ready"
    assert_includes link, "buyer=Pasada"
    get link
    assert_select "a[href*='retail_orders?'][href*='status=ready']", text: "Volver al listado"
  end

  test "filtros manipulados se ignoran sin romper ni inyectar SQL" do
    create_retail
    sign_in @admin

    get admin_retail_orders_path(status: "x'; DROP TABLE retail_orders;--", kind: "zzz", payment_status: ["a"], date_from: "no", page: "-9", buyer: "%' OR 1=1 --")
    assert_response :success
    assert_equal 1, RetailOrder.count
  end

  # --- producción ---

  test "producción muestra la columna HANS y la sección de productos especiales; sirve también la impresión" do
    day = Date.new(2026, 10, 21)
    wholesale_order(@mini, 20, day)
    create_retail(attributes: { delivery_date: day.iso8601, buyer_name: "Compradora Uno", delivery_time_note: "11 hs" },
                  items: [product_row(@mini, 12, "500"), manual_row("Torta especial", 1, "8.000")])

    sign_in @production_user
    get admin_production_path(day)
    assert_response :success
    assert_match "HANS", response.body
    assert_match "PRODUCTOS ESPECIALES — HANS", response.body
    assert_match "Torta especial", response.body
    assert_match "Compradora Uno", response.body
    assert_match "11 hs", response.body
    assert_no_match "5555-1234", response.body, "producción no ve teléfonos"
    assert_no_match "8.000", response.body, "producción no ve precios"

    get print_admin_production_path(day)
    assert_response :success
    assert_match "PRODUCTOS ESPECIALES — HANS", response.body

    sign_out @production_user
    get public_production_print_path(day)
    assert_response :success
    assert_match "PRODUCTOS ESPECIALES — HANS", response.body
    assert_match(/>\s*32\s*</, response.body)
  end

  test "índice de producción incluye días con solo pedidos minoristas" do
    create_retail(attributes: { delivery_date: (Date.current + 2).iso8601 })
    sign_in @production_user
    get admin_production_index_path
    assert_response :success
    assert_match "1 pedido", response.body.gsub(/\s+/, " ")
  end
end
