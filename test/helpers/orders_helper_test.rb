require "test_helper"

class OrdersHelperTest < ActionView::TestCase
  test "paid maps to the green bg-success class" do
    assert_equal "bg-success", payment_status_badge_class("paid")
  end

  test "partial maps to the amber/orange bg-warning class" do
    assert_equal "bg-warning text-dark", payment_status_badge_class("partial")
  end

  test "pending maps to a yellow class distinct from partial's, never red" do
    klass = payment_status_badge_class("pending")

    assert_equal "bg-warning-subtle text-warning-emphasis", klass
    assert_not_equal payment_status_badge_class("partial"), klass
    assert_no_match(/danger/, klass)
  end

  test "falls back to bg-secondary for an unknown/blank status instead of raising" do
    assert_equal "bg-secondary", payment_status_badge_class(nil)
    assert_equal "bg-secondary", payment_status_badge_class("something_else")
  end
end
