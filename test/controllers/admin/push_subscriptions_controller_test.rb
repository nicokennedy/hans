require "test_helper"

class Admin::PushSubscriptionsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "pushsubctrl-admin@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "pushsubctrl-production@example.com", password: "password123", role: "production")
    @customer_record = Customer.create!(name: "PushSubCtrlCustomer", active: true)
    @customer_user = User.create!(email: "pushsubctrl-customer@example.com", password: "password123", role: "customer", customer: @customer_record)
  end

  teardown do
    PushSubscription.where(user_id: [ @admin.id, @production_user.id, @customer_user.id ]).destroy_all
    User.where(id: [ @admin.id, @production_user.id, @customer_user.id ]).destroy_all
    @customer_record.destroy
  end

  test "admin can register a subscription" do
    sign_in @admin

    assert_difference "PushSubscription.count", 1 do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-1", keys: { p256dh: "p", auth: "a" } }
      }
    end

    assert_response :success
    assert_equal @admin, PushSubscription.find_by(endpoint: "https://push.example.com/ctrl-1").user
  end

  test "production can register a subscription" do
    sign_in @production_user

    assert_difference "PushSubscription.count", 1 do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-prod", keys: { p256dh: "p", auth: "a" } }
      }
    end

    assert_response :success
  end

  test "a customer cannot register a subscription" do
    sign_in @customer_user

    assert_no_difference "PushSubscription.count" do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-customer", keys: { p256dh: "p", auth: "a" } }
      }
    end

    assert_redirected_to dashboard_path
  end

  test "an unauthenticated request cannot register a subscription" do
    assert_no_difference "PushSubscription.count" do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-anon", keys: { p256dh: "p", auth: "a" } }
      }
    end

    assert_response :redirect
  end

  test "registering the same endpoint twice updates it (idempotent), does not create a duplicate row" do
    sign_in @admin

    post admin_push_subscriptions_path, params: {
      subscription: { endpoint: "https://push.example.com/ctrl-idempotent", keys: { p256dh: "p1", auth: "a1" } }
    }

    assert_no_difference "PushSubscription.count" do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-idempotent", keys: { p256dh: "p2", auth: "a2" } }
      }
    end

    subscription = PushSubscription.find_by(endpoint: "https://push.example.com/ctrl-idempotent")
    assert_equal "p2", subscription.p256dh_key
  end

  test "registering an endpoint already owned by another user reassigns it to the current user (shared device)" do
    sign_in @admin
    post admin_push_subscriptions_path, params: {
      subscription: { endpoint: "https://push.example.com/ctrl-shared", keys: { p256dh: "p", auth: "a" } }
    }
    sign_out @admin

    sign_in @production_user
    assert_no_difference "PushSubscription.count" do
      post admin_push_subscriptions_path, params: {
        subscription: { endpoint: "https://push.example.com/ctrl-shared", keys: { p256dh: "p", auth: "a" } }
      }
    end

    subscription = PushSubscription.find_by(endpoint: "https://push.example.com/ctrl-shared")
    assert_equal @production_user, subscription.user
  end

  test "a user can only delete their own subscription" do
    sign_in @admin
    post admin_push_subscriptions_path, params: {
      subscription: { endpoint: "https://push.example.com/ctrl-delete-mine", keys: { p256dh: "p", auth: "a" } }
    }
    mine = PushSubscription.find_by(endpoint: "https://push.example.com/ctrl-delete-mine")
    sign_out @admin

    sign_in @production_user
    other = PushSubscription.create!(user: @production_user, endpoint: "https://push.example.com/ctrl-other", p256dh_key: "p", auth_key: "a")

    assert_no_difference "PushSubscription.count" do
      delete admin_push_subscription_path(mine)
    end
    assert_response :not_found

    assert_difference "PushSubscription.count", -1 do
      delete admin_push_subscription_path(other)
    end
    assert_response :no_content
  end

  test "sending a test notification only targets the current user's own subscription" do
    sign_in @admin
    subscription = PushSubscription.create!(user: @admin, endpoint: "https://push.example.com/ctrl-test", p256dh_key: "p", auth_key: "a")

    endpoints_called = []
    WebPush.stub(:payload_send, ->(**kwargs) { endpoints_called << kwargs[:endpoint] }) do
      post test_admin_push_subscription_path(subscription)
    end

    assert_equal [ subscription.endpoint ], endpoints_called
  end

  test "cannot send a test notification for another user's subscription" do
    sign_in @admin
    other = PushSubscription.create!(user: @production_user, endpoint: "https://push.example.com/ctrl-test-other", p256dh_key: "p", auth_key: "a")

    post test_admin_push_subscription_path(other)

    assert_response :not_found
  end
end
