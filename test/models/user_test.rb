require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "production role is a valid, distinct enum value that does not disturb customer/admin" do
    user = User.new(email: "role-check@example.com", password: "password123", role: "production")
    assert user.valid?
    assert_equal "production", user.role
    assert user.production?
    assert_not user.admin?
    assert_not user.customer?
  end

  test "admin_or_production? is true for admin and production, false for customer" do
    admin = User.new(role: "admin")
    production = User.new(role: "production")
    customer = User.new(role: "customer")

    assert admin.admin_or_production?
    assert production.admin_or_production?
    assert_not customer.admin_or_production?
  end

  test "can_view_orders? and can_view_production? mirror admin_or_production?" do
    production = User.new(role: "production")
    customer = User.new(role: "customer")

    assert production.can_view_orders?
    assert production.can_view_production?
    assert_not customer.can_view_orders?
    assert_not customer.can_view_production?
  end

  test "default role is still customer, unaffected by adding production" do
    assert_equal "customer", User.new.role
  end

  test "driver role is a valid, distinct role outside admin and production" do
    driver = User.new(email: "driver-check@example.com", password: "password123", role: "driver")
    assert driver.valid?
    assert driver.driver?
    assert_not driver.admin?
    assert_not driver.production?
    assert_not driver.admin_or_production?
    assert_not driver.can_view_orders?
  end

  test "only the driver is always remembered, with its own period" do
    driver = User.new(role: "driver")
    admin = User.new(role: "admin")

    assert driver.remember_me
    assert driver.extend_remember_period
    assert_not admin.remember_me
    assert_not admin.extend_remember_period
    assert_in_delta User::DRIVER_REMEMBER_FOR.from_now, driver.remember_expires_at, 5
    assert_in_delta User.remember_for.from_now, admin.remember_expires_at, 5
  end
end
