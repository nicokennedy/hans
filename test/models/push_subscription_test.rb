require "test_helper"

class PushSubscriptionTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(email: "pushsub-admin@example.com", password: "password123", role: "admin")
  end

  teardown do
    PushSubscription.where(user_id: @admin.id).destroy_all
    User.where(id: @admin.id).destroy_all
  end

  test "belongs to a user, required" do
    subscription = PushSubscription.new(endpoint: "https://push.example.com/1", p256dh_key: "p", auth_key: "a")
    assert_not subscription.valid?
    assert subscription.errors[:user].present?
  end

  test "endpoint must be unique" do
    PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/dup", p256dh_key: "p", auth_key: "a")
    duplicate = PushSubscription.new(user: @admin, endpoint: "https://push.example.com/dup", p256dh_key: "p2", auth_key: "a2")

    assert_not duplicate.valid?
    assert duplicate.errors[:endpoint].present?
  end

  test "a user can have several device subscriptions" do
    PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/device-a", p256dh_key: "p", auth_key: "a")
    PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/device-b", p256dh_key: "p", auth_key: "a")

    assert_equal 2, @admin.push_subscriptions.count
  end

  test "eligible_for_order_notifications includes admin and production, excludes customer" do
    production_user = User.create!(email: "pushsub-production@example.com", password: "password123", role: "production")
    customer_record = Customer.create!(name: "PushSubCustomer", active: true)
    customer_user = User.create!(email: "pushsub-customer@example.com", password: "password123", role: "customer", customer: customer_record)

    admin_sub = PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/admin-dev", p256dh_key: "p", auth_key: "a")
    production_sub = PushSubscription.create!(user: production_user, endpoint: "https://push.example.com/production-dev", p256dh_key: "p", auth_key: "a")
    customer_sub = PushSubscription.create!(user: customer_user, endpoint: "https://push.example.com/customer-dev", p256dh_key: "p", auth_key: "a")

    eligible = PushSubscription.eligible_for_order_notifications
    assert_includes eligible, admin_sub
    assert_includes eligible, production_sub
    assert_not_includes eligible, customer_sub
  ensure
    PushSubscription.where(id: [ admin_sub&.id, production_sub&.id, customer_sub&.id ]).destroy_all
    User.where(email: [ production_user&.email, customer_user&.email ]).destroy_all
    customer_record&.destroy
  end

  test "to_web_push_subscription returns the shape the web-push gem expects" do
    subscription = PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/shape", p256dh_key: "p256", auth_key: "auth123")

    assert_equal(
      { endpoint: "https://push.example.com/shape", keys: { p256dh: "p256", auth: "auth123" } },
      subscription.to_web_push_subscription
    )
  end
end
