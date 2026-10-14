require "test_helper"
require_relative "../../support/visibility_helpers"
require_relative "../../support/retail_helpers"

# Admin → Productos (configuración de disponibilidad por cliente), pedidos del admin y minoristas.
class Admin::ProductVisibilityAdminTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include VisibilityHelpers

  setup { setup_visibility }

  def product_params(overrides = {})
    { product: { name: "Nuevo Prod #{rand(1_000_000)}", category_id: @category.id, price_amount: 100, customer_visibility: "all_customers" }.merge(overrides) }
  end

  # --- formulario de producto ---

  test "el formulario ofrece Todos / Solo clientes seleccionados con buscador y lista de clientes" do
    sign_in @admin
    get new_admin_product_path

    assert_select "fieldset#customer-access legend", text: "Disponibilidad por cliente"
    assert_select "input[type=radio][name='product[customer_visibility]']", 2
    assert_select "label", text: "Todos los clientes"
    assert_select "label", text: "Solo clientes seleccionados"
    assert_select "input[type=search][data-customer-access-target='search']"
    assert_select "input[type=checkbox][name='product[authorized_customer_ids][]']", minimum: 3
    assert_select "input#product_visibility_all[checked]"
  end

  test "crear un producto disponible para todos (por defecto)" do
    sign_in @admin
    assert_difference "Product.count", 1 do
      post admin_products_path, params: product_params
    end
    assert Product.order(:id).last.all_customers?
  end

  test "crear un producto restringido a clientes seleccionados" do
    sign_in @admin
    assert_difference "Product.count", 1 do
      post admin_products_path, params: product_params(customer_visibility: "selected_customers", authorized_customer_ids: ["", @cafe_a.id.to_s, @cafe_c.id.to_s, @cafe_a.id.to_s])
    end
    product = Product.order(:id).last
    assert product.selected_customers?
    assert_equal [@cafe_a.id, @cafe_c.id].sort, product.authorized_customer_ids.sort
    assert_equal 2, ProductCustomerAccess.where(product_id: product.id).count
  end

  test "no se puede guardar un producto restringido sin clientes" do
    sign_in @admin
    assert_no_difference ["Product.count", "ProductCustomerAccess.count"] do
      post admin_products_path, params: product_params(customer_visibility: "selected_customers", authorized_customer_ids: [""])
    end
    assert_response :unprocessable_entity
    assert_match "al menos un cliente", response.body
  end

  test "un valor de visibilidad inválido no rompe el servidor" do
    sign_in @admin
    assert_no_difference "Product.count" do
      post admin_products_path, params: product_params(customer_visibility: "cualquiera")
    end
    assert_response :unprocessable_entity
  end

  test "al editar se muestra la configuración guardada y se puede cambiar" do
    sign_in @admin
    get edit_admin_product_path(@special_abc)

    assert_select "input#product_visibility_selected[checked]"
    [@cafe_a, @cafe_b, @cafe_c].each { |c| assert_select "input#product_customer_#{c.id}[checked]" }

    patch admin_product_path(@special_abc), params: { product: { customer_visibility: "selected_customers", authorized_customer_ids: ["", @cafe_b.id.to_s] } }
    assert_redirected_to admin_products_path
    assert_equal [@cafe_b.id], @special_abc.reload.authorized_customer_ids
  end

  test "pasar de restringido a todos desde el formulario" do
    sign_in @admin
    patch admin_product_path(@exclusive_a), params: { product: { customer_visibility: "all_customers", authorized_customer_ids: [@cafe_a.id.to_s] } }

    assert @exclusive_a.reload.all_customers?
    assert_equal 0, ProductCustomerAccess.where(product_id: @exclusive_a.id).count
  end

  test "editar otros datos sin tocar la disponibilidad no la cambia" do
    sign_in @admin
    patch admin_product_path(@exclusive_a), params: { product: { name: "Renombrado #{rand(1_000_000)}", price_amount: 12 } }

    assert @exclusive_a.reload.selected_customers?
    assert_equal [@cafe_a.id], @exclusive_a.authorized_customer_ids
    assert_equal 1200, @exclusive_a.price_cents
  end

  test "el listado muestra Todos o Restringido (N clientes) y quiénes tienen acceso sin editar" do
    sign_in @admin
    get admin_products_path

    assert_response :success
    assert_select "th", text: "Disponibilidad"
    assert_select "span.badge", text: "Restringido (1 cliente)"
    assert_select "span.badge", text: "Restringido (3 clientes)"
    assert_select "span.badge", text: "Todos", minimum: 1
    assert_select "details li", text: @cafe_b.name
  end

  test "el listado de productos no tiene consultas por producto para los clientes" do
    10.times { |i| make_product("Lista #{i} #{rand(1_000_000)}", 100, customers: [@cafe_a, @cafe_b]) }
    sign_in @admin
    queries = Hash.new(0)
    counter = ->(*, payload) { queries[payload[:sql][/FROM "?(\w+)"?/, 1]] += 1 if payload[:sql].match?(/customers|product_customer_accesses/) }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { get admin_products_path }

    assert_operator queries.values.sum, :<=, 3
  end

  test "solo admin puede configurar la disponibilidad" do
    [@user_a].each do |user|
      sign_in user
      patch admin_product_path(@rogel), params: { product: { customer_visibility: "selected_customers", authorized_customer_ids: [@cafe_a.id.to_s] } }
      assert_response :redirect
      assert @rogel.reload.all_customers?
      sign_out user
    end
    patch admin_product_path(@rogel), params: { product: { customer_visibility: "selected_customers", authorized_customer_ids: [@cafe_a.id.to_s] } }
    assert @rogel.reload.all_customers?
  end

  # --- pedidos cargados por el admin ---

  def admin_order_params(customer, product, extra = {})
    { order: { customer_id: customer.id, delivery_date: @delivery.iso8601, status: "received" }, order_items: [{ product_id: product.id, quantity: 2 }] }.merge(extra)
  end

  test "el formulario del admin indica qué productos están habilitados para el cliente" do
    sign_in @admin
    get new_admin_order_path

    assert_select "select[name='order_items[][product_id]'] option[data-visibility='selected'][data-customer-ids='#{@cafe_a.id}']", text: @exclusive_a.name
    assert_select "select[name='order_items[][product_id]'] option[data-visibility='all']", text: @rogel.name
    assert_select "input#allow_restricted_exception"
    assert_match "excepción administrativa", response.body
  end

  test "el admin crea un pedido para un cliente con productos habilitados" do
    sign_in @admin
    assert_difference "Order.count", 1 do
      post admin_orders_path, params: admin_order_params(@cafe_a, @exclusive_a)
    end
    assert_nil Order.last.order_items.first.restriction_override_by_id
  end

  test "el admin no puede asignar por error un producto restringido a un cliente no autorizado" do
    sign_in @admin
    assert_no_difference ["Order.count", "OrderItem.count"] do
      post admin_orders_path, params: admin_order_params(@cafe_b, @exclusive_a)
    end
    assert_response :unprocessable_entity
    assert_match "no está disponible para este cliente", response.body
  end

  test "excepción administrativa explícita: se permite y queda auditada" do
    sign_in @admin
    assert_difference "Order.count", 1 do
      post admin_orders_path, params: admin_order_params(@cafe_b, @exclusive_a, allow_restricted_exception: "1")
    end
    item = Order.last.order_items.first
    assert_equal @admin, item.restriction_override_by
    assert_not_nil item.restriction_override_at
  end

  test "la excepción solo se registra en los ítems que la necesitan" do
    sign_in @admin
    post admin_orders_path, params: { order: { customer_id: @cafe_b.id, delivery_date: @delivery.iso8601, status: "received" },
                                      order_items: [{ product_id: @rogel.id, quantity: 1 }, { product_id: @exclusive_a.id, quantity: 1 }], allow_restricted_exception: "1" }
    items = Order.last.order_items.index_by(&:product_id)

    assert_nil items[@rogel.id].restriction_override_by_id
    assert_equal @admin.id, items[@exclusive_a.id].restriction_override_by_id
  end

  test "editar un pedido histórico: cambios que no agregan productos siguen funcionando" do
    order = wholesale_order_for(@cafe_a, [[@exclusive_a, 3]])
    @exclusive_a.update!(authorized_customers: [@cafe_c])
    item = order.order_items.first
    sign_in @admin

    patch admin_order_path(order), params: { order: { delivery_date: order.delivery_date, status: order.status, customer_comment: "nota" },
                                             order_items: { item.id.to_s => { quantity: 2, unit_price_amount: 8 } } }
    assert_redirected_to admin_order_path(order)
    assert_equal 2, item.reload.quantity
    assert_equal "nota", order.reload.customer_comment
  end

  test "editar un pedido: aumentar la cantidad de un producto no autorizado se bloquea (y con excepción se registra)" do
    order = wholesale_order_for(@cafe_a, [[@exclusive_a, 3]])
    @exclusive_a.update!(authorized_customers: [@cafe_c])
    item = order.order_items.first
    sign_in @admin
    params = { order: { delivery_date: order.delivery_date, status: order.status }, order_items: { item.id.to_s => { quantity: 5, unit_price_amount: 9 } } }

    patch admin_order_path(order), params: params
    assert_response :unprocessable_entity
    assert_match "no está disponible para este cliente", response.body
    assert_equal 3, item.reload.quantity

    patch admin_order_path(order), params: params.merge(allow_restricted_exception: "1")
    assert_redirected_to admin_order_path(order)
    assert_equal 5, item.reload.quantity
    assert_equal @admin.id, item.restriction_override_by_id
  end

  test "editar un pedido: agregar una línea nueva de un producto no autorizado se bloquea" do
    order = wholesale_order_for(@cafe_b, [[@rogel, 1]])
    sign_in @admin

    patch admin_order_path(order), params: { order: { delivery_date: order.delivery_date, status: order.status }, new_order_items: [{ product_id: @exclusive_a.id, quantity: 1 }] }

    assert_response :unprocessable_entity
    assert_equal [@rogel.id], order.reload.order_items.pluck(:product_id)
  end

  test "editar un pedido: reemplazar un producto por uno no autorizado se bloquea sin perder el original" do
    order = wholesale_order_for(@cafe_b, [[@rogel, 2]])
    item = order.order_items.first
    sign_in @admin

    patch admin_order_path(order), params: { order: { delivery_date: order.delivery_date, status: order.status }, order_items: { item.id.to_s => { product_id: @exclusive_a.id, quantity: 2 } } }

    assert_response :unprocessable_entity
    assert_equal @rogel.id, item.reload.product_id
  end

  # --- pedidos minoristas, producción, stock ---

  test "los pedidos minoristas siguen aceptando cualquier producto de catálogo, restringido o no" do
    sign_in @admin
    get new_admin_retail_order_path
    assert_response :success
    assert_select "select[name='items[0][product_id]'] option", text: @exclusive_a.name

    result = Retail::SaveOrder.call(
      order: RetailOrder.new,
      attributes: { buyer_name: "Compradora", delivery_date: @delivery.iso8601, delivery_kind: "pickup" },
      items: [{ "kind" => "product", "product_id" => @exclusive_a.id.to_s, "quantity" => "2", "unit_price" => "1.500" }, { "kind" => "manual", "description" => "Torta", "quantity" => "1", "unit_price" => "100" }],
      user: @admin
    )

    assert result.ok?, result.errors.inspect
    assert_equal 900, @exclusive_a.reload.price_cents, "el precio del producto no cambia"
    assert_equal 2, ProductionDaySheet.for(@delivery).rows.find { |r| r[:product_id] == @exclusive_a.id }[:total]
  end

  test "restringir un producto no cambia la producción de pedidos ya cargados ni los movimientos de stock" do
    wholesale_order_for(@cafe_a, [[@exclusive_a, 4]])
    before = [ProductionDaySheet.for(@delivery).rows.map { |r| [r[:product_id], r[:total]] }, StockMovement.count, StockItem.count]

    @exclusive_a.update!(authorized_customers: [@cafe_c])

    assert_equal before, [ProductionDaySheet.for(@delivery).rows.map { |r| [r[:product_id], r[:total]] }, StockMovement.count, StockItem.count]
  end
end
