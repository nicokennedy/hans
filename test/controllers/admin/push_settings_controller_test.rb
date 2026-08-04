require "test_helper"

class Admin::PushSettingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "pushsettings-admin@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "pushsettings-production@example.com", password: "password123", role: "production")
    @customer_record = Customer.create!(name: "PushSettingsCustomer", active: true)
    @customer_user = User.create!(email: "pushsettings-customer@example.com", password: "password123", role: "customer", customer: @customer_record)
  end

  teardown do
    User.where(id: [ @admin.id, @production_user.id, @customer_user.id ]).destroy_all
    @customer_record.destroy
  end

  test "admin can access the notifications settings page" do
    sign_in @admin
    get admin_push_settings_path
    assert_response :success
    assert_match "Notificaciones de pedidos", response.body
  end

  test "production can access the notifications settings page" do
    sign_in @production_user
    get admin_push_settings_path
    assert_response :success
  end

  test "a customer cannot access the notifications settings page" do
    sign_in @customer_user
    get admin_push_settings_path
    assert_redirected_to dashboard_path
  end

  test "the VAPID private key is never rendered in the page source" do
    original = ENV["WEB_PUSH_VAPID_PRIVATE_KEY"]
    ENV["WEB_PUSH_VAPID_PRIVATE_KEY"] = "super-secret-private-key-value"

    sign_in @admin
    get admin_push_settings_path

    assert_no_match "super-secret-private-key-value", response.body
  ensure
    ENV["WEB_PUSH_VAPID_PRIVATE_KEY"] = original
  end
end
