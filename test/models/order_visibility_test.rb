require "test_helper"
require_relative "../support/visibility_helpers"

# Visibilidad de productos por cliente en el modelo de pedidos (garantía de servidor).
class OrderVisibilityTest < ActiveSupport::TestCase
  include VisibilityHelpers

  setup { setup_visibility }

  test "fecha de prueba válida para pedidos mayoristas" do
    assert_nil DeliveryDateValidator.reason(@delivery)
  end

  test "cliente autorizado puede pedir productos públicos y exclusivos" do
    order = wholesale_order_for(@cafe_a, [[@rogel, 2], [@exclusive_a, 1], [@special_abc, 3]])

    assert order.persisted?
    assert_equal 3, order.order_items.count
  end

  test "cliente no autorizado no puede pedir un producto exclusivo y no se guarda nada" do
    order = Order.new(customer: @cafe_b, delivery_date: @delivery)
    order.order_items.build(product: @rogel, quantity: 1)
    order.order_items.build(product: @exclusive_a, quantity: 1)

    assert_no_difference ["Order.count", "OrderItem.count"] do
      assert_not order.save
    end
    assert_equal ["#{@exclusive_a.name}: este producto no está disponible para tu cliente."], order.errors.full_messages
  end

  test "el admin que crea el pedido tampoco puede asignar un producto no habilitado sin excepción" do
    order = Order.new(customer: @cafe_b, delivery_date: @delivery, created_by_admin: true)
    order.order_items.build(product: @exclusive_a, quantity: 1)

    assert_not order.save
    assert_match(/no está disponible para este cliente/, order.errors.full_messages.join)
  end

  test "excepción administrativa explícita: queda registrada con quién y cuándo" do
    order = Order.new(customer: @cafe_b, delivery_date: @delivery, created_by_admin: true)
    item = order.order_items.build(product: @exclusive_a, quantity: 1)
    item.restriction_override_by = @admin
    item.restriction_override_at = Time.current

    assert order.save
    assert_equal @admin, order.order_items.first.restriction_override_by
    assert_equal Time.current.to_i, order.order_items.first.restriction_override_at.to_i
  end

  test "producto inactivo o restringido no afecta los pedidos de productos públicos" do
    assert wholesale_order_for(@cafe_b, [[@rogel, 1], [@special_abc, 1]]).persisted?
  end

  # --- pedidos históricos ---

  def historical_order_then_restrict
    order = wholesale_order_for(@cafe_a, [[@rogel, 4]])
    @rogel.update!(customer_visibility: "selected_customers", authorized_customers: [@cafe_b]) # deja de estar habilitado para A
    order.reload
  end

  test "un pedido histórico conserva sus ítems y sigue visible cuando el producto deja de estar habilitado" do
    order = historical_order_then_restrict

    assert_equal [@rogel.id], order.order_items.map(&:product_id)
    assert_equal @rogel.name, order.order_items.first.product_name_snapshot
    assert_equal 4, order.order_items.first.quantity
    assert_equal 500, order.order_items.first.unit_price_cents_snapshot
    assert order.valid?
  end

  test "editar un pedido histórico sin agregar ni sustituir productos sigue siendo posible" do
    order = historical_order_then_restrict
    item = order.order_items.first

    item.quantity = 2 # bajar la cantidad
    assert item.save
    item.unit_price_amount = 7 # corregir el precio
    assert item.save
    assert order.update(customer_comment: "comentario nuevo")
    assert order.update(delivery_date: Date.new(2026, 10, 9))
  end

  test "no se pueden agregar unidades de un producto que ya no está autorizado" do
    order = historical_order_then_restrict
    item = order.order_items.first

    item.quantity = 5
    assert_not item.save
    assert_match(/no está disponible para este cliente/, item.errors.full_messages.join)
    assert_equal 4, item.reload.quantity
  end

  test "no se puede sumar el producto no autorizado como línea nueva ni reemplazar por él" do
    order = wholesale_order_for(@cafe_b, [[@rogel, 1]])
    new_item = order.order_items.build(product: @exclusive_a, quantity: 1)
    assert_not new_item.save

    item = order.order_items.first
    item.assign_product(@exclusive_a)
    assert_not item.save
    assert_equal @rogel.id, item.reload.product_id
  end

  test "con excepción administrativa se pueden agregar unidades" do
    order = historical_order_then_restrict
    item = order.order_items.first
    item.quantity = 6
    item.restriction_override_by = @admin
    item.restriction_override_at = Time.current

    assert item.save
    assert_equal 6, item.reload.quantity
  end

  test "reasignar el pedido a otro cliente exige que los productos estén habilitados para él" do
    order = wholesale_order_for(@cafe_a, [[@exclusive_a, 1]])

    assert_not order.update(customer: @cafe_b)
    assert_match(/no está disponible para este cliente/, order.errors.full_messages.join)
    assert_equal @cafe_a.id, order.reload.customer_id

    assert order.update(customer: @cafe_c) == false
    order.order_items.first.update_columns(restriction_override_by_id: @admin.id, restriction_override_at: Time.current)
    assert order.reload.update(customer: @cafe_c), "con excepción registrada se permite"
  end

  test "la visibilidad no altera producción, stock ni precios de un pedido existente" do
    order = wholesale_order_for(@cafe_a, [[@rogel, 3]])
    before = [Order.find(order.id).total_cents, StockMovement.count, ProductionDaySheet.for(@delivery).rows.map { |r| [r[:product_id], r[:total]] }, @rogel.price_cents]

    @rogel.update!(customer_visibility: "selected_customers", authorized_customers: [@cafe_b])

    assert_equal before, [Order.find(order.id).total_cents, StockMovement.count, ProductionDaySheet.for(@delivery).rows.map { |r| [r[:product_id], r[:total]] }, @rogel.reload.price_cents]
  end
end
