require "test_helper"
require "csv"

# Filtros de Admin → Pedidos recibidos (cliente, fecha de entrega, estado de pago) y
# conservación del contexto (filtros + página) al abrir un pedido, registrar un pago,
# editar o recargar. El contexto viaja en query params validados, nunca en una URL.
class Admin::OrdersFiltersTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  D9 = Date.new(2026, 10, 9)
  D10 = Date.new(2026, 10, 10)

  setup do
    @admin = User.create!(email: "ofilters-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @cook = User.create!(email: "ofilters-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    category = Category.create!(name: "OFCat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Alfajor OF #{rand(1_000_000)}", category: category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    @honey = Customer.create!(name: "Honey #{rand(1_000_000)}", active: true)
    @other = Customer.create!(name: "Otro Cliente #{rand(1_000_000)}", active: true)
    @inactive = Customer.create!(name: "Cliente Inactivo #{rand(1_000_000)}", active: false)

    @honey_d9_pending = build_order(@honey, D9)
    @honey_d9_paid = build_order(@honey, D9, paid: true)
    @honey_d10_pending = build_order(@honey, D10)
    @other_d9_pending = build_order(@other, D9)
    @other_d10_partial = build_order(@other, D10, partial: true)

    sign_in @admin
  end

  def build_order(customer, date, paid: false, partial: false, quantity: 2)
    order = Order.new(customer: customer, delivery_date: date, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: quantity) # total quantity * 300
    order.save!
    order.payments.create!(amount_cents: order.total_cents, paid_at: Time.current, payment_method: "cash_on_delivery") if paid
    order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery") if partial
    order.reload
  end

  def listed_numbers
    css_select(".product-card .fw-bold").map(&:text).map(&:strip).grep(/\AHANS-/)
  end

  def numbers(*orders)
    orders.map(&:number)
  end

  # --- Filtros ------------------------------------------------------------------

  test "filtra por cliente y no mezcla pedidos de otros" do
    get admin_orders_path, params: { customer_id: @honey.id }

    assert_response :success
    assert_equal numbers(@honey_d9_pending, @honey_d9_paid, @honey_d10_pending).sort, listed_numbers.sort
    assert_select "#orders-filters input[name=customer_id][value=?]", @honey.id.to_s
    assert_select "#orders-filter-customer[value=?]", @honey.name
    assert_select "#orders-filter-customer[name]", count: 0 # el texto no viaja en la URL: solo customer_id
  end

  test "filtra por fecha de entrega (delivery_date), no por la fecha de creación" do
    get admin_orders_path, params: { delivery_date: D10.iso8601 }

    assert_response :success
    assert_equal numbers(@honey_d10_pending, @other_d10_partial).sort, listed_numbers.sort
    assert_select "#orders-filters input[name=delivery_date][value=?]", D10.iso8601

    # la fecha de creación no cuenta: un pedido creado el 10/10 pero entregado el 09/10 no aparece al filtrar por el 10/10
    @honey_d9_pending.update_columns(created_at: Time.zone.local(2026, 10, 10, 12))
    get admin_orders_path, params: { delivery_date: D10.iso8601 }
    assert_not_includes listed_numbers, @honey_d9_pending.number
    assert_equal numbers(@honey_d10_pending, @other_d10_partial).sort, listed_numbers.sort
  end

  test "filtra por estado de pago con la lógica existente (pendiente, parcial, pagado)" do
    get admin_orders_path, params: { payment_status_filter: "pending" }
    assert_equal numbers(@honey_d9_pending, @honey_d10_pending, @other_d9_pending).sort, listed_numbers.sort

    get admin_orders_path, params: { payment_status_filter: "partial" }
    assert_equal numbers(@other_d10_partial), listed_numbers

    get admin_orders_path, params: { payment_status_filter: "paid" }
    assert_equal numbers(@honey_d9_paid), listed_numbers

    get admin_orders_path, params: { payment_status_filter: "all" }
    assert_equal 5, listed_numbers.size
  end

  test "combina cliente + fecha + estado de pago" do
    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }

    assert_response :success
    assert_equal numbers(@honey_d9_pending), listed_numbers
    assert_select "#orders-count", text: /1 pedido · filtrado/
  end

  test "cliente + fecha sin estado de pago, y fecha + estado sin cliente" do
    get admin_orders_path, params: { customer_id: @other.id, delivery_date: D10.iso8601, payment_status_filter: "all" }
    assert_equal numbers(@other_d10_partial), listed_numbers

    get admin_orders_path, params: { delivery_date: D9.iso8601, payment_status_filter: "pending" }
    assert_equal numbers(@honey_d9_pending, @other_d9_pending).sort, listed_numbers.sort
  end

  test "el selector de clientes lista todos los clientes (también inactivos) para autocompletar por nombre" do
    get admin_orders_path

    names = css_select("#orders-filter-customers option").map { |o| o["value"] }
    assert_includes names, @honey.name
    assert_includes names, @inactive.name
    assert_equal Customer.count, names.size
    assert_select "#orders-filter-customers option[data-id=?]", @honey.id.to_s
  end

  test "el formulario trae los tres filtros y los botones Aplicar filtros y Limpiar filtros" do
    get admin_orders_path

    assert_select "#orders-filters label", text: "Cliente"
    assert_select "#orders-filters label", text: "Fecha de entrega"
    assert_select "#orders-filters label", text: "Estado de pago"
    assert_select "#orders-filters input[type=submit][value=?]", "Aplicar filtros"
    assert_select "#orders-filters a#orders-clear-filters", text: "Limpiar filtros"
    assert_select "#orders-filter-customer[placeholder=?]", "Todos los clientes"
  end

  test "Limpiar filtros vuelve al listado general (también el estado de pago guardado)" do
    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "paid" }
    assert_equal 1, listed_numbers.size

    get css_select("#orders-clear-filters").first["href"]
    assert_response :success
    assert_equal 5, listed_numbers.size

    get admin_orders_path # la sesión ya no conserva el filtro de pago
    assert_equal 5, listed_numbers.size
  end

  test "export CSV respeta cliente, fecha y estado de pago" do
    get export_admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "paid" }

    rows = CSV.parse(response.body.delete_prefix("﻿"), headers: true)
    assert_equal [@honey_d9_paid.number], rows.map { |r| r["Número de pedido"] }.uniq
  end

  test "el link Exportar CSV arrastra los filtros vigentes" do
    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending", page: 1 }

    assert_select "a[href=?]", export_admin_orders_path(customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending"), text: "Exportar CSV"
  end

  # --- Contexto de navegación -------------------------------------------------------

  test "cada pedido del listado enlaza al detalle con los filtros vigentes" do
    filters = { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }
    get admin_orders_path, params: filters

    assert_select "a[href=?]", admin_order_path(@honey_d9_pending, filters)
  end

  test "Caso 1/2/3: el Volver del detalle regresa al listado con cliente, fecha y estado de pago" do
    filters = { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }
    get admin_order_path(@honey_d9_pending, filters)

    assert_response :success
    assert_select "a#back-to-orders[href=?]", admin_orders_path(filters)

    # sigue funcionando al recargar la pantalla de detalle
    get admin_order_path(@honey_d9_pending, filters)
    assert_select "a#back-to-orders[href=?]", admin_orders_path(filters)

    get css_select("#back-to-orders").first["href"]
    assert_equal numbers(@honey_d9_pending), listed_numbers
  end

  test "después de registrar un pago se conserva el contexto" do
    filters = { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }
    get admin_order_path(@honey_d9_pending, filters)

    assert_select "form[action=?] input[type=hidden][name=customer_id][value=?]", admin_order_payments_path(@honey_d9_pending), @honey.id.to_s
    assert_select "form[action=?] input[type=hidden][name=delivery_date][value=?]", admin_order_payments_path(@honey_d9_pending), D9.iso8601
    assert_select "form[action=?] input[type=hidden][name=payment_status_filter][value=?]", admin_order_payments_path(@honey_d9_pending), "pending"

    assert_difference "Payment.count", 1 do
      post admin_order_payments_path(@honey_d9_pending), params: filters.merge(payment: { amount: "2", paid_at: Date.current, payment_method: "cash_on_delivery", note: "Seña" })
    end

    assert_redirected_to admin_order_path(@honey_d9_pending, filters)
    follow_redirect!
    assert_select "a#back-to-orders[href=?]", admin_orders_path(filters)
    assert_equal 200, @honey_d9_pending.reload.amount_paid_cents
    assert_equal "partial", @honey_d9_pending.payment_status
  end

  test "un pago rechazado también conserva el contexto" do
    filters = { customer_id: @honey.id, page: 2 }
    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@honey_d9_pending), params: filters.merge(payment: { amount: "", paid_at: Date.current, payment_method: "cash_on_delivery" })
    end

    assert_redirected_to admin_order_path(@honey_d9_pending, customer_id: @honey.id, page: 2)
  end

  test "eliminar un pago conserva el contexto" do
    payment = @honey_d9_paid.payments.first
    filters = { customer_id: @honey.id, delivery_date: D9.iso8601 }

    get admin_order_path(@honey_d9_paid, filters)
    assert_select "form[action=?] input[name=customer_id][value=?]", admin_order_payment_path(@honey_d9_paid, payment), @honey.id.to_s

    delete admin_order_payment_path(@honey_d9_paid, payment), params: filters
    assert_redirected_to admin_order_path(@honey_d9_paid, filters)
  end

  test "al editar el pedido se conserva el contexto: link, formulario, volver y redirect al guardar" do
    filters = { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending", page: 1 }
    ctx = { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }

    get admin_order_path(@honey_d9_pending, filters)
    assert_select "a[href=?]", edit_admin_order_path(@honey_d9_pending, ctx), text: "Editar pedido"

    get edit_admin_order_path(@honey_d9_pending, ctx)
    assert_select "a[href=?]", admin_order_path(@honey_d9_pending, ctx), text: /Volver al pedido/
    assert_select "form input[type=hidden][name=customer_id][value=?]", @honey.id.to_s

    patch admin_order_path(@honey_d9_pending), params: ctx.merge(order: { customer_comment: "Tocar timbre" })
    assert_redirected_to admin_order_path(@honey_d9_pending, ctx)
    assert_equal "Tocar timbre", @honey_d9_pending.reload.customer_comment
  end

  test "una edición inválida vuelve a mostrar el formulario sin perder el contexto" do
    ctx = { customer_id: @honey.id }
    patch admin_order_path(@honey_d9_pending), params: ctx.merge(order: { delivery_date: "" })

    assert_response :unprocessable_entity
    assert_select "a[href=?]", admin_order_path(@honey_d9_pending, ctx), text: /Volver al pedido/
    assert_select "form input[type=hidden][name=customer_id][value=?]", @honey.id.to_s
  end

  test "acceso directo al pedido, sin contexto: Volver lleva al listado general" do
    get admin_order_path(@honey_d9_pending)

    assert_response :success
    assert_select "a#back-to-orders[href=?]", admin_orders_path
    assert_select "form input[type=hidden][name=customer_id]", count: 0
  end

  # --- Paginación -------------------------------------------------------------------

  test "paginación de 50 en 50: conserva filtros en los links y el Volver devuelve a la misma página" do
    # 55 pedidos de Honey para el 11/10 (más los 3 anteriores = 58 de Honey)
    55.times { build_order(@honey, Date.new(2026, 10, 11), quantity: 1) }

    get admin_orders_path, params: { customer_id: @honey.id }
    assert_equal 50, listed_numbers.size
    assert_select "#orders-pagination", text: /Página 1 de 2/
    assert_select "#orders-pagination a[rel=next][href=?]", admin_orders_path(customer_id: @honey.id, page: 2)
    assert_select "#orders-pagination a[rel=prev]", count: 0

    get admin_orders_path, params: { customer_id: @honey.id, page: 2 }
    assert_equal 8, listed_numbers.size
    assert_select "#orders-pagination a[rel=prev][href=?]", admin_orders_path(customer_id: @honey.id)

    link = css_select("a.text-decoration-none[href^='/admin/orders/']").first["href"]
    assert_includes link, "page=2"
    assert_includes link, "customer_id=#{@honey.id}"

    get link
    assert_select "a#back-to-orders[href=?]", admin_orders_path(customer_id: @honey.id, page: 2)
  end

  test "una página fuera de rango se acota a la última y no deja el listado vacío" do
    get admin_orders_path, params: { page: 999 }

    assert_response :success
    assert_equal 5, listed_numbers.size
    assert_select "#orders-pagination", count: 0
  end

  # --- Parámetros inválidos o manipulados --------------------------------------------

  test "valores inválidos se ignoran sin romper: cliente, fecha, estado de pago y página" do
    [
      { customer_id: "abc" },
      { customer_id: "999999999" },
      { customer_id: "1 OR 1=1" },
      { customer_id: "'; DROP TABLE orders; --" },
      { customer_id: ["1"] },
      { customer_id: { "0" => "1" } },
      { delivery_date: "no-es-fecha" },
      { delivery_date: "2026-13-45" },
      { delivery_date: ["2026-10-09"] },
      { payment_status_filter: "<script>alert(1)</script>" },
      { payment_status_filter: ["paid"] },
      { page: "-3" },
      { page: "abc" },
      { page: "99999999999999999999" }
    ].each do |params|
      get admin_orders_path, params: params
      assert_response :success, "falló con #{params.inspect}"
      assert_equal 5, listed_numbers.size, "debería ignorar #{params.inspect}"
    end
    assert_equal 5, Order.count
  end

  test "una fecha inválida se informa en pantalla" do
    get admin_orders_path, params: { delivery_date: "2026-13-45" }

    assert_match "La fecha de entrega no era válida", response.body
  end

  test "no hay redirects abiertos: return_to, back o URLs en los params se ignoran" do
    post admin_order_payments_path(@honey_d9_pending), params: {
      return_to: "https://evil.example.com", back: "//evil.example.com", redirect: "javascript:alert(1)",
      customer_id: "https://evil.example.com",
      payment: { amount: "1", paid_at: Date.current, payment_method: "cash_on_delivery" }
    }

    assert_redirected_to admin_order_path(@honey_d9_pending)
    assert_no_match(/evil/, response.location)

    get admin_order_path(@honey_d9_pending, return_to: "https://evil.example.com", customer_id: "//evil.example.com")
    assert_select "a#back-to-orders[href=?]", admin_orders_path
    assert_empty css_select("a[href*=evil], form[action*=evil], input[value*=evil]"), "ningún link ni campo con la URL manipulada"
  end

  test "un cliente_id válido pero ajeno al contexto igual se valida contra la base" do
    get admin_order_path(@honey_d9_pending, customer_id: @other.id)

    assert_select "a#back-to-orders[href=?]", admin_orders_path(customer_id: @other.id)
  end

  # --- Production -------------------------------------------------------------------

  test "production filtra por cliente y fecha, sin estado de pago, y el contexto no filtra por pagos" do
    sign_out @admin
    sign_in @cook

    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "paid" }

    assert_response :success
    assert_equal numbers(@honey_d9_pending, @honey_d9_paid).sort, listed_numbers.sort, "el filtro de pago se ignora para production"
    assert_select "#orders-filters select[name=payment_status_filter]", count: 0
    assert_select "#orders-filter-customer"
    assert_no_match(/Saldo:/, response.body)

    get admin_order_path(@honey_d9_pending, customer_id: @honey.id, payment_status_filter: "paid")
    assert_select "a#back-to-orders[href=?]", admin_orders_path(customer_id: @honey.id)
  end

  # --- Sin efectos secundarios -----------------------------------------------------

  test "filtrar y navegar no altera pagos, saldos, estados ni pedidos" do
    snapshot = -> { [Payment.count, Payment.order(:id).pluck(:id, :amount_cents), Order.order(:id).pluck(:id, :status, :payment_status, :amount_paid_cents, :total_cents, :delivery_date, :updated_at), OrderItem.order(:id).pluck(:id, :quantity), StockMovement.count] }
    before = snapshot.call

    get admin_orders_path, params: { customer_id: @honey.id, delivery_date: D9.iso8601, payment_status_filter: "pending" }
    get admin_order_path(@honey_d9_pending, customer_id: @honey.id)
    get edit_admin_order_path(@honey_d9_pending, customer_id: @honey.id)
    get export_admin_orders_path, params: { customer_id: @honey.id }

    assert_equal before, snapshot.call
  end

  test "registrar un pago con contexto cambia solo ese pago y su saldo" do
    others_before = Order.where.not(id: @honey_d9_pending.id).order(:id).pluck(:id, :amount_paid_cents, :payment_status)

    post admin_order_payments_path(@honey_d9_pending), params: { customer_id: @honey.id, payment: { amount: "6", paid_at: Date.current, payment_method: "cash_on_delivery" } }

    @honey_d9_pending.reload
    assert_equal 600, @honey_d9_pending.amount_paid_cents
    assert_equal "paid", @honey_d9_pending.payment_status
    assert_equal 0, @honey_d9_pending.balance_due_cents
    assert_equal others_before, Order.where.not(id: @honey_d9_pending.id).order(:id).pluck(:id, :amount_paid_cents, :payment_status)
  end
end
