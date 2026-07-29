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
end
