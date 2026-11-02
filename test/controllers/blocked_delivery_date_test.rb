require "test_helper"

# Bloqueo puntual del sábado 07/11/2026 (BlockedDate): los clientes no pueden elegirlo ni
# enviarlo a mano; el sábado siguiente y los días habituales siguen igual; el admin conserva
# su permiso de cargar y editar pedidos en cualquier fecha; los pedidos existentes no cambian.
class BlockedDeliveryDateTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  BLOCKED = Date.new(2026, 11, 7)
  MESSAGE = "No habrá entregas el sábado 7 de noviembre".freeze
  NOW = Time.zone.local(2026, 11, 2, 12, 0, 0) # lunes de esa semana

  setup do
    BlockedDate.delete_all
    BlockedDate.create!(date: BLOCKED, reason: MESSAGE, active: true)
    n = rand(1_000_000)
    category = Category.create!(name: "Bloqueo #{n}", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Bloqueo #{n}", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente Bloqueo #{n}", active: true)
    @user = User.create!(email: "bloqueo-#{n}@example.com", password: "password123", role: "customer", customer: @customer)
    @admin = User.create!(email: "bloqueo-admin-#{n}@example.com", password: "password123", role: "admin")
  end

  def customer_checkout(date)
    sign_in @user
    post add_cart_path, params: { product_id: @product.id }
    post orders_path, params: { order: { delivery_date: date.iso8601, payment_method_selected: "cash_on_delivery" } }
  end

  test "validador: el 07/11 queda bloqueado con su motivo y gana sobre una excepción habilitada" do
    assert_equal MESSAGE, DeliveryDateValidator.reason(BLOCKED, now: NOW)

    DeliverySetting.current.add_exceptional_date!(BLOCKED)
    assert_equal MESSAGE, DeliveryDateValidator.reason(BLOCKED, now: NOW)
  end

  test "validador: el sábado 14/11 y los otros sábados siguen habilitados" do
    [Date.new(2026, 11, 14), Date.new(2026, 11, 21), Date.new(2026, 11, 28)].each do |saturday|
      assert DeliveryDateValidator.available?(saturday, now: NOW), "#{saturday} debería estar habilitado"
    end
  end

  test "validador: lunes, miércoles y viernes de esa semana sin cambios; martes, jueves y domingo siguen cerrados" do
    [Date.new(2026, 11, 9), Date.new(2026, 11, 4), Date.new(2026, 11, 6)].each do |day|
      assert DeliveryDateValidator.available?(day, now: NOW), "#{day} debería estar habilitado"
    end
    [Date.new(2026, 11, 3), Date.new(2026, 11, 5), Date.new(2026, 11, 8)].each do |day|
      assert_match "No realizamos entregas los martes, jueves ni domingos", DeliveryDateValidator.reason(day, now: NOW)
    end
  end

  test "validador: un bloqueo inactivo no bloquea y uno sin motivo usa el mensaje genérico" do
    BlockedDate.update_all(active: false)
    assert DeliveryDateValidator.available?(BLOCKED, now: NOW)

    BlockedDate.create!(date: Date.new(2026, 11, 9), active: true)
    assert_equal "Fecha bloqueada manualmente", DeliveryDateValidator.reason(Date.new(2026, 11, 9), now: NOW)
  end

  test "cliente: el calendario deshabilita el 07/11 y no el 14/11" do
    travel_to NOW do
      sign_in @user
      post add_cart_path, params: { product_id: @product.id }
      get new_order_path

      assert_response :success
      blocked = response.body[/const blockedDates = (\[[^\]]*\])/, 1]
      assert_equal ["2026-11-07"], JSON.parse(blocked)
      assert_match "if (blockedDates.includes(iso)) return true", response.body
    end
  end

  test "cliente: el backend rechaza el 07/11 enviado a mano, con el mensaje claro" do
    travel_to NOW do
      assert_no_difference "Order.count" do
        customer_checkout(BLOCKED)
      end

      assert_response :unprocessable_entity
      assert_match MESSAGE, response.body
    end
  end

  test "cliente: puede pedir para el sábado 14/11 y para el viernes 06/11" do
    travel_to NOW do
      [Date.new(2026, 11, 14), Date.new(2026, 11, 6)].each do |date|
        assert_difference "Order.count", 1 do
          customer_checkout(date)
        end
        assert_equal date, @customer.orders.order(:id).last.delivery_date
      end
    end
  end

  test "admin: puede crear un pedido para el 07/11" do
    travel_to NOW do
      sign_in @admin
      assert_difference "Order.count", 1 do
        post admin_orders_path, params: {
          order: { customer_id: @customer.id, delivery_date: BLOCKED.iso8601, status: "received", payment_method_selected: "cash_on_delivery" },
          order_items: [{ product_id: @product.id, quantity: "2", unit_price_amount: "5" }]
        }
      end

      order = Order.order(:id).last
      assert_redirected_to admin_order_path(order)
      assert_equal BLOCKED, order.delivery_date
    end
  end

  test "admin: puede mover un pedido al 07/11 y editar uno que ya está en esa fecha" do
    travel_to NOW do
      order = @customer.orders.new(delivery_date: Date.new(2026, 11, 6), payment_method_selected: "cash_on_delivery")
      order.order_items.build(product: @product, quantity: 1)
      order.save!

      sign_in @admin
      patch admin_order_path(order), params: { order: { delivery_date: BLOCKED.iso8601 } }
      assert_redirected_to admin_order_path(order)
      assert_equal BLOCKED, order.reload.delivery_date

      patch admin_order_path(order), params: { order: { customer_comment: "Retira el lunes" } }
      assert_redirected_to admin_order_path(order)
      assert_equal "Retira el lunes", order.reload.customer_comment
    end
  end

  test "pedidos existentes para el 07/11 no se modifican por el bloqueo" do
    BlockedDate.delete_all
    existing = travel_to(NOW) do
      o = @customer.orders.new(delivery_date: BLOCKED, payment_method_selected: "cash_on_delivery")
      o.order_items.build(product: @product, quantity: 3)
      o.save!
      o
    end
    snapshot = -> { existing.reload.attributes.except("updated_at") }
    before = snapshot.call

    BlockedDate.create!(date: BLOCKED, reason: MESSAGE, active: true)
    travel_to NOW do
      sign_in @user
      get order_path(existing)
      assert_response :success
      get orders_path
      assert_response :success
    end

    assert_equal before, snapshot.call
    assert existing.reload.valid?, "un pedido ya existente sigue siendo válido (la fecha se valida solo al crear)"
  end
end
