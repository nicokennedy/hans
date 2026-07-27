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

  test "matches the exact required format: customer, order, delivery date, blank line, then products" do
    message = Notifications::OrderWhatsappMessage.new(@order).to_s

    expected = [
      "Cliente: Café Central",
      "Pedido: #{@order.number}",
      "Entrega: 25/07/2026",
      "",
      "• Medialunas x24",
      "• Pan de molde x6"
    ].join("\n")

    assert_equal expected, message
  end

  test "never includes the old banner, total or order link" do
    message = Notifications::OrderWhatsappMessage.new(@order).to_s

    assert_no_match(/Nuevo pedido recibido/, message)
    assert_no_match(/Total/, message)
    assert_no_match(/Ver pedido/, message)
    assert_no_match(%r{https?://}, message)
  end

  test "lists every product line, not just the first one" do
    message = Notifications::OrderWhatsappMessage.new(@order).to_s

    product_lines = message.lines.select { |line| line.start_with?("•") }
    assert_equal 2, product_lines.size
  end
end
