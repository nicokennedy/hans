require "test_helper"

class Admin::ProductionControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "should get index" do
    get admin_production_index_url
    assert_response :success
  end

  test "show displays the WhatsApp button using the configured number, not the old hardcoded one" do
    admin = User.create!(email: "production-whatsapp-admin@example.com", password: "password123", role: "admin")
    category = Category.create!(name: "Alfajores", position: 1, active: true)
    product = Product.create!(name: "Alfajor Clásico", category: category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    customer = Customer.create!(name: "Cliente Test", active: true)
    order = Order.new(customer: customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: product, quantity: 2)
    order.save!

    sign_in admin

    with_whatsapp_number("5492235275412") do
      get admin_production_path(order.delivery_date)

      assert_response :success
      assert_match "wa.me/5492235275412", response.body
      assert_no_match "5492914168790", response.body
    end
  end

  test "show hides the WhatsApp button when WHATSAPP_OBRADOR_NUMBER is not configured" do
    admin = User.create!(email: "production-whatsapp-admin2@example.com", password: "password123", role: "admin")
    sign_in admin

    with_whatsapp_number(nil) do
      get admin_production_path(Date.tomorrow)

      assert_response :success
      assert_no_match "wa.me", response.body
      assert_match "no disponible", response.body
    end
  end

  private

  def with_whatsapp_number(value)
    original = ENV["WHATSAPP_OBRADOR_NUMBER"]
    ENV["WHATSAPP_OBRADOR_NUMBER"] = value
    yield
  ensure
    ENV["WHATSAPP_OBRADOR_NUMBER"] = original
  end
end
