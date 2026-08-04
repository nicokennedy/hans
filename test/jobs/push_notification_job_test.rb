require "test_helper"

class PushNotificationJobTest < ActiveJob::TestCase
  setup do
    @category = Category.create!(name: "PushJobCat", position: 1, active: true)
    @product = Product.create!(name: "PushJobProd", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "PushJobCustomer", active: true)

    @order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    @order.order_items.build(product: @product, quantity: 2)
    @order.save!

    @admin = User.create!(email: "pushjob-admin@example.com", password: "password123", role: "admin")
    @subscription = PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/pushjob-1", p256dh_key: "p", auth_key: "a")

    ENV["WEB_PUSH_VAPID_PUBLIC_KEY"] = "test-public-key"
    ENV["WEB_PUSH_VAPID_PRIVATE_KEY"] = "test-private-key"
    ENV["WEB_PUSH_VAPID_SUBJECT"] = "mailto:test@hans.example.com"
  end

  teardown do
    ENV.delete("WEB_PUSH_VAPID_PUBLIC_KEY")
    ENV.delete("WEB_PUSH_VAPID_PRIVATE_KEY")
    ENV.delete("WEB_PUSH_VAPID_SUBJECT")

    PushSubscription.where(user_id: @admin.id).destroy_all
    @order.payments.destroy_all
    @order.order_items.destroy_all
    @order.destroy
    User.where(id: @admin.id).destroy_all
    Customer.where(id: @customer.id).destroy_all
    Product.where(id: @product.id).destroy_all
    Category.where(id: @category.id).destroy_all
  end

  test "sends to every eligible subscription with a payload containing no cost/margin figures" do
    sent_payloads = []
    WebPush.stub(:payload_send, ->(**kwargs) { sent_payloads << kwargs[:message] }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_equal 1, sent_payloads.size
    payload = JSON.parse(sent_payloads.first)

    assert_equal "Nuevo pedido HANS", payload["title"]
    assert_equal "Pedido #{@order.number} — #{@customer.name}", payload["body"]
    assert_equal "order-#{@order.id}", payload["tag"]
    assert_equal @order.id, payload["order_id"]
    refute payload.to_s.include?("cost_cents")
    refute payload.to_s.match?(/margen|cost/i)
  end

  test "does not send to a customer's subscription even if one exists" do
    customer_record = Customer.create!(name: "PushJobCustomerUser", active: true)
    customer_user = User.create!(email: "pushjob-customer@example.com", password: "password123", role: "customer", customer: customer_record)
    customer_subscription = PushSubscription.create!(user: customer_user, endpoint: "https://push.example.com/pushjob-customer", p256dh_key: "p", auth_key: "a")

    endpoints_sent_to = []
    WebPush.stub(:payload_send, ->(**kwargs) { endpoints_sent_to << kwargs[:endpoint] }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_includes endpoints_sent_to, @subscription.endpoint
    assert_not_includes endpoints_sent_to, customer_subscription.endpoint
  ensure
    customer_subscription&.destroy
    customer_user&.destroy
    customer_record&.destroy
  end

  test "continues sending to remaining subscriptions if one fails" do
    other_admin = User.create!(email: "pushjob-admin2@example.com", password: "password123", role: "admin")
    other_subscription = PushSubscription.create!(user: other_admin, endpoint: "https://push.example.com/pushjob-2", p256dh_key: "p", auth_key: "a")

    call_count = 0
    WebPush.stub(:payload_send, ->(**kwargs) {
      call_count += 1
      raise WebPush::PushServiceError.new(OpenStruct.new(body: "boom"), "push.example.com") if kwargs[:endpoint] == @subscription.endpoint
    }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_equal 2, call_count
    assert PushSubscription.exists?(@subscription.id) # transient failure: not deleted
  ensure
    other_subscription&.destroy
    other_admin&.destroy
  end

  test "deletes the subscription when the push service reports it expired (410)" do
    WebPush.stub(:payload_send, ->(**kwargs) { raise WebPush::ExpiredSubscription.new(OpenStruct.new(body: "gone"), "push.example.com") }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_not PushSubscription.exists?(@subscription.id)
  end

  test "deletes the subscription when the push service reports it invalid (404)" do
    WebPush.stub(:payload_send, ->(**kwargs) { raise WebPush::InvalidSubscription.new(OpenStruct.new(body: "not found"), "push.example.com") }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_not PushSubscription.exists?(@subscription.id)
  end

  test "does not delete the subscription on a transient server error (5xx)" do
    WebPush.stub(:payload_send, ->(**kwargs) { raise WebPush::PushServiceError.new(OpenStruct.new(body: "server error"), "push.example.com") }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert PushSubscription.exists?(@subscription.id)
  end

  test "does not delete the subscription on a VAPID authorization error, since that is a server misconfiguration" do
    WebPush.stub(:payload_send, ->(**kwargs) { raise WebPush::Unauthorized.new(OpenStruct.new(body: "unauthorized"), "push.example.com") }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert PushSubscription.exists?(@subscription.id)
  end

  test "does nothing (and does not raise) when VAPID is not configured" do
    ENV.delete("WEB_PUSH_VAPID_PRIVATE_KEY")

    calls = 0
    WebPush.stub(:payload_send, ->(**kwargs) { calls += 1 }) do
      PushNotificationJob.perform_now(@order.id)
    end

    assert_equal 0, calls
  end

  test "does nothing if the order no longer exists (e.g. deleted before the job ran)" do
    calls = 0
    WebPush.stub(:payload_send, ->(**kwargs) { calls += 1 }) do
      PushNotificationJob.perform_now(-1)
    end

    assert_equal 0, calls
  end

  test "the deduplication tag is stable for the same order across multiple sends (re-running the job is safe)" do
    tags = []
    WebPush.stub(:payload_send, ->(**kwargs) { tags << JSON.parse(kwargs[:message])["tag"] }) do
      PushNotificationJob.perform_now(@order.id)
      PushNotificationJob.perform_now(@order.id)
    end

    assert_equal tags.uniq, tags
  end
end
