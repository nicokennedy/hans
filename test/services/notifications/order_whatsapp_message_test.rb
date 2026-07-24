require "test_helper"

class Notifications::OrderWhatsappMessageTest < ActiveSupport::TestCase
  setup do
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Medialunas", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @other_product = Product.create!(name: "Pan de molde", category: @category, price_cents: 300, cost_cents: 100, active: true, position: 2)
    @customer = Customer.create!(name: "Café Central", active: true)

    @order = Order.new(customer: @customer, delivery_date: Date.new(2026, 7, 25))
    @order.order_items.build(product: @product, quantity: 24)
    @order.order_items.build(product: @other_product, quantity: 6)
    @order.save!
  end

  test "includes the banner, order number, customer, delivery date, products with quantities, total and order link" do
    admin_url = "https://hans.example.com/admin/orders/#{@order.id}"
    message = Notifications::OrderWhatsappMessage.new(@order, admin_url).to_s

    assert_includes message, "🟢 Nuevo pedido recibido"
    assert_includes message, "Pedido: #{@order.number}"
    assert_includes message, "Cliente: Café Central"
    assert_includes message, "Entrega: 25/07/2026"
    assert_includes message, "• Medialunas x24"
    assert_includes message, "• Pan de molde x6"
    assert_includes message, "Total: $#{ActionController::Base.helpers.number_with_delimiter(@order.total_cents / 100)}"
    assert_includes message, "Ver pedido: #{admin_url}"
  end

  test "lists every product line, not just the first one" do
    message = Notifications::OrderWhatsappMessage.new(@order, "https://example.com").to_s

    product_lines = message.lines.select { |line| line.start_with?("•") }
    assert_equal 2, product_lines.size
  end
end
