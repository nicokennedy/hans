require "test_helper"

class OrdersChannelTest < ActionCable::Channel::TestCase
  def setup
    @admin = User.create!(email: "orderschannel-admin@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "orderschannel-production@example.com", password: "password123", role: "production")
    @customer_record = Customer.create!(name: "OrdersChannelCustomer", active: true)
    @customer_user = User.create!(email: "orderschannel-customer@example.com", password: "password123", role: "customer", customer: @customer_record)
  end

  def teardown
    User.where(email: [ @admin.email, @production_user.email, @customer_user.email ]).destroy_all
    @customer_record.destroy
  end

  test "admin can subscribe and gets streamed the shared orders stream" do
    stub_connection current_user: @admin
    subscribe

    assert subscription.confirmed?
    assert_has_stream "orders_channel"
  end

  test "production can subscribe" do
    stub_connection current_user: @production_user
    subscribe

    assert subscription.confirmed?
    assert_has_stream "orders_channel"
  end

  test "customer cannot subscribe" do
    stub_connection current_user: @customer_user
    subscribe

    assert subscription.rejected?
  end

  test "an unauthenticated connection (no current_user) cannot subscribe" do
    stub_connection current_user: nil
    subscribe

    assert subscription.rejected?
  end

  test "broadcast_order_created includes the order_created type and reaches the shared stream" do
    payload = { order_id: 1, order_number: "HANS-TEST", customer_name: "Café Test" }

    assert_broadcast_on("orders_channel", payload.merge(type: "order_created")) do
      OrdersChannel.broadcast_order_created(payload)
    end
  end
end
