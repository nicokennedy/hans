require "test_helper"

# Pantalla "Ver historial" de un StockItem (Admin::StockItemsController#show):
# tarjetas por movimiento, filtros, paginación, permisos y solo lectura.
class Admin::StockHistoryTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  DAY = Date.new(2026, 10, 5)

  setup do
    @admin = User.create!(email: "hist-ui-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @cook = User.create!(email: "hist-ui-cook-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "Cliente HistUI #{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "hist-ui-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)
    @customer = customer
    category = Category.create!(name: "HistUICat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Alfajor HistUI #{rand(1_000_000)}", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @item = StockItem.create!(stockable: @product, active: true, quantity: 0, minimum_quantity: 12, stock_tracking_started_on: DAY)
  end

  def at(day, hour, min = 0, &block)
    travel_to(Time.zone.local(2026, 10, day, hour, min, 0), &block)
  end

  def order_for(delivery_date, quantity: 3)
    order = Order.new(customer: @customer, delivery_date: delivery_date, status: "received", created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: quantity)
    order.save!
    order
  end

  def history_page(params = {})
    get admin_stock_item_path(@item, params)
    assert_response :success
  end

  # --- Encabezado --------------------------------------------------------------

  test "muestra nombre, unidad, stock actual y mínimo, y el estado vacío sin movimientos" do
    sign_in @admin
    history_page

    assert_select "h1", text: @product.name
    assert_match "Unidad: un", response.body
    assert_select "#history-current-stock", text: "0 un"
    assert_select "#history-minimum", text: "12 un"
    assert_select ".stock-move", count: 0
    assert_match "Todavía no hay movimientos registrados", response.body
  end

  # --- Tarjetas ----------------------------------------------------------------

  test "producción: ingreso en verde con usuario, comentario, fecha y hora de Argentina y stock resultante" do
    # 12:35 UTC = 09:35 en Buenos Aires
    travel_to(Time.utc(2026, 10, 8, 12, 35)) do
      Stock::RegisterProduction.call(stock_item: @item, quantity: 10, user: @cook, note: "Producción de la mañana")
    end

    sign_in @admin
    history_page

    assert_select ".stock-move.stock-move--in", count: 1
    assert_select ".stock-move__qty", text: "+10 un"
    assert_select ".stock-move__kind", text: "Producción"
    assert_select ".stock-move__time", text: "08/10/2026 - 09:35"
    assert_select ".stock-move__line", text: /Por:\s*#{Regexp.escape(@cook.email)}/
    assert_select ".stock-move__line", text: /Comentario:\s*Producción de la mañana/
    assert_select ".stock-move__balance", text: /Stock resultante:\s*10 un/
  end

  test "ajuste manual negativo: egreso en rojo con el motivo cargado" do
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 28, user: @cook) }
    at(5, 10) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 26, user: @admin, note: "Dos unidades descartadas por rotura") }

    sign_in @admin
    history_page

    assert_select ".stock-move.stock-move--out .stock-move__qty", text: "-2 un"
    assert_select ".stock-move.stock-move--out .stock-move__kind", text: "Ajuste manual"
    assert_select ".stock-move__line", text: /Dos unidades descartadas por rotura/
    assert_select ".stock-move__balance", text: /Stock resultante:\s*26 un/
  end

  test "venta: pedido, link al detalle, cliente y fecha de entrega; el pedido registrado antes muestra ambas fechas" do
    order = nil
    at(3, 10) { order = order_for(DAY) }
    at(5, 14) { Stock::DispatchReconciler.reconcile_due! }

    sign_in @admin
    history_page

    assert_select ".stock-move.stock-move--out .stock-move__qty", text: "-3 un"
    assert_select ".stock-move__kind", text: "Venta"
    assert_select ".stock-move__line a[href=?]", admin_order_path(order), text: "Ver pedido"
    assert_select ".stock-move__line strong", text: order.number
    assert_select ".stock-move__line", text: /Entrega: 05\/10\/2026.*Pedido registrado: 03\/10\/2026/m
    assert_select ".stock-move__line", text: /Descuento automático por pedido/
    assert_select ".stock-move__products li", text: /#{Regexp.escape(@product.name)}.*3/m
  end

  test "si el pedido se registra el mismo día de la entrega no repite la fecha de registro" do
    at(5, 14) { order_for(DAY) }

    sign_in @admin
    at(5, 15) { history_page }

    assert_no_match(/Pedido registrado/, response.body)
  end

  test "cancelación: corrección en verde que referencia el pedido cancelado" do
    order = nil
    at(5, 14) { order = order_for(DAY) }
    at(5, 15) { order.update!(status: "canceled") }

    sign_in @admin
    history_page

    assert_select ".stock-move--in .stock-move__qty", text: "+3 un"
    assert_select ".stock-move--in .stock-move__kind", text: "Cancelación / corrección de pedido"
    assert_select ".stock-move--in .stock-move__line", text: /El pedido figura cancelado/
    assert_select ".stock-move--in .badge", text: "Pedido cancelado"
    assert_select ".stock-move--in a[href=?]", admin_order_path(order)
    assert_select ".stock-move", count: 2 # la venta original y UNA corrección, nada duplicado
  end

  test "movimientos anteriores sin usuario: 'Usuario no registrado' y nunca un usuario ficticio" do
    @item.apply_movement!(movement_type: :production, quantity: 5)
    @item.apply_movement!(movement_type: :adjustment, quantity: -1)

    sign_in @admin
    history_page

    assert_select ".stock-move__line", text: /Usuario no registrado/, count: 2
    assert_no_match(/@example\.com/, response.body.scan(/stock-move__line.*?<\/div>/m).join)
  end

  # --- Filtros y paginación -------------------------------------------------------

  test "filtros por tipo y rango de fechas" do
    at(5, 9) { Stock::RegisterProduction.call(stock_item: @item, quantity: 20, user: @cook) }
    at(6, 9) { Stock::RegisterAdjustment.call(stock_item: @item, counted_quantity: 19, user: @admin, note: "rotura") }
    at(7, 14) { order_for(Date.new(2026, 10, 7)) }

    sign_in @admin

    history_page
    assert_select ".stock-move", count: 3

    history_page(kind: "production")
    assert_select ".stock-move", count: 1
    assert_select ".stock-move__kind", text: "Producción"
    assert_select ".stock-history-filters a.btn-dark", text: /Producción/

    history_page(kind: "sale")
    assert_select ".stock-move__kind", text: "Venta", count: 1
    assert_select ".stock-move", count: 1

    history_page(kind: "adjustment")
    assert_select ".stock-move__kind", text: "Ajuste manual", count: 1

    history_page(kind: "correction")
    assert_select ".stock-move", count: 0
    assert_match "No hay movimientos que coincidan con el filtro", response.body

    history_page(from: "2026-10-06", to: "2026-10-06")
    assert_select ".stock-move", count: 1
    assert_select ".stock-move__kind", text: "Ajuste manual"

    history_page(kind: "bogus", from: "no-es-fecha")
    assert_select ".stock-move", count: 3
    assert_match "Alguna fecha no era válida", response.body
  end

  test "paginación de 25 en 25 con links que conservan el filtro" do
    at(5, 9) { 30.times { |i| @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook, note: "mov #{i}") } }
    at(5, 10) { 3.times { @item.apply_movement!(movement_type: :adjustment, quantity: -1, user: @admin) } }

    sign_in @admin
    history_page(kind: "production")
    assert_select ".stock-move", count: 25
    assert_match "Página 1 de 2", response.body
    assert_select "a[rel=next][href=?]", admin_stock_item_path(@item, kind: "production", page: 2)

    history_page(kind: "production", page: 2)
    assert_select ".stock-move", count: 5
    assert_select "a[rel=prev][href=?]", admin_stock_item_path(@item, kind: "production", page: 1)
    assert_select "a[rel=next]", count: 0
  end

  # --- Panel de Stock: botón y comentario --------------------------------------------

  test "cada tarjeta del panel de stock tiene el botón 'Ver historial'" do
    sign_in @admin
    get admin_stock_path

    assert_select "a.btn[href=?]", admin_stock_item_path(@item, anchor: "stock-history"), text: "Ver historial"

    sign_out @admin
    sign_in @cook
    get admin_stock_path
    assert_select "a.btn", text: "Ver historial"
  end

  test "los formularios de producción y conteo tienen comentario opcional y se guarda en el movimiento" do
    sign_in @admin
    get admin_stock_path
    assert_select "form[action=?] input[name=note]", register_production_admin_stock_item_path(@item)
    assert_select "form[action=?] input[name=note]", register_count_admin_stock_item_path(@item)

    post register_production_admin_stock_item_path(@item), params: { quantity: 10, note: "  Producción   de la mañana " }
    post register_count_admin_stock_item_path(@item), params: { counted_quantity: 8, note: "Dos por rotura" }
    post register_production_admin_stock_item_path(@item), params: { quantity: 1 }

    notes = @item.stock_movements.order(:id).pluck(:note)
    assert_equal ["Producción de la mañana", "Dos por rotura", nil], notes
    assert_equal @admin.id, @item.stock_movements.order(:id).first.user_id

    history_page
    assert_select ".stock-move__line", text: /Comentario:\s*Dos por rotura/
    assert_select ".stock-move__line", text: /Por:\s*#{Regexp.escape(@admin.email)}/, minimum: 1
  end

  test "un comentario larguísimo se acota en vez de fallar" do
    sign_in @admin
    post register_production_admin_stock_item_path(@item), params: { quantity: 1, note: "a" * 900 }

    assert_operator @item.stock_movements.first.note.length, :<=, 500
  end

  # --- Permisos y solo lectura ----------------------------------------------------

  test "permisos: admin y production ven el historial (igual que el panel); cliente y visitante no" do
    @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook)

    sign_in @admin
    get admin_stock_item_path(@item)
    assert_response :success
    sign_out @admin

    sign_in @cook
    get admin_stock_item_path(@item)
    assert_response :success
    sign_out @cook

    sign_in @customer_user
    get admin_stock_item_path(@item)
    assert_redirected_to dashboard_path
    sign_out @customer_user

    get admin_stock_item_path(@item)
    assert_redirected_to new_user_session_path
  end

  test "el historial no ofrece editar ni borrar movimientos y esas rutas no existen" do
    @item.apply_movement!(movement_type: :production, quantity: 1, user: @cook)
    movement = @item.stock_movements.first
    sign_in @admin
    history_page

    section = css_select("#stock-history").first
    assert_empty section.css("form[method=post]"), "no hay formularios que modifiquen movimientos"
    assert_empty section.css("input[name=_method]")
    assert_no_match(/Eliminar|Borrar/, section.to_s)

    delete "/admin/stock_movements/#{movement.id}"
    assert_response :not_found
    patch "/admin/stock_movements/#{movement.id}", params: { stock_movement: { quantity: 99 } }
    assert_response :not_found
    assert_equal 1, StockMovement.count
    assert_equal BigDecimal(1), movement.reload.quantity
  end

  test "ver el historial no cambia stock, movimientos ni pedidos" do
    order = nil
    at(5, 14) { order = order_for(DAY) }
    at(5, 15) { Stock::RegisterProduction.call(stock_item: @item, quantity: 6, user: @cook) }
    before = [StockMovement.count, @item.reload.quantity, @item.updated_at, order.reload.updated_at, order.status, order.order_items.pluck(:quantity)]

    sign_in @admin
    at(5, 16) do
      history_page
      history_page(kind: "sale", from: "2026-10-01")
    end

    assert_equal before, [StockMovement.count, @item.reload.quantity, @item.updated_at, order.reload.updated_at, order.status, order.order_items.pluck(:quantity)]
  end
end
