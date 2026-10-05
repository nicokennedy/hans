require "test_helper"

# Camino real: POST del conteo/producción y luego volver a abrir el panel.
class Admin::StockCountReconciliationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "countctrl-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    category = Category.create!(name: "CountCtrlCat#{rand(1_000_000)}", position: 1, active: true)
    customer = Customer.create!(name: "Cliente CountCtrl #{rand(1_000_000)}", active: true)
    product = Product.create!(name: "Producto CountCtrl", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @item = StockItem.create!(stockable: product, active: true, quantity: 20, minimum_quantity: 5, stock_tracking_started_on: Date.new(2026, 1, 1))
    travel_to(Time.zone.local(2026, 10, 6, 9, 0, 0)) do
      order = Order.new(customer: customer, delivery_date: Date.new(2026, 10, 6), created_by_admin: true, payment_method_selected: "cash_on_delivery")
      order.order_items.build(product: product, quantity: 5)
      order.save!
    end
  end

  test "contar después de las 13:00 y volver a abrir el panel deja el físico contado, sin descontar de nuevo" do
    sign_in @admin

    travel_to Time.zone.local(2026, 10, 6, 14, 0, 0) do
      post register_count_admin_stock_item_path(@item), params: { counted_quantity: 12 }
      assert_redirected_to admin_stock_path
      assert_equal BigDecimal(12), @item.reload.quantity

      2.times { get admin_stock_path; assert_response :success }

      assert_equal BigDecimal(12), @item.reload.quantity
      assert_equal 1, StockMovement.dispatch.count
    end
  end

  test "registrar producción después de las 13:00 concilia primero la salida pendiente" do
    sign_in @admin

    travel_to Time.zone.local(2026, 10, 6, 14, 0, 0) do
      post register_production_admin_stock_item_path(@item), params: { quantity: 10 }

      assert_equal %w[dispatch production], StockMovement.order(:id).pluck(:movement_type)
      assert_equal BigDecimal(25), @item.reload.quantity
    end
  end
end
