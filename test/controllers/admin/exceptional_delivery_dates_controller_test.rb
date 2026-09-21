require "test_helper"

class Admin::ExceptionalDeliveryDatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "exdates-admin@example.com", password: "password123", role: "admin")
    sign_in @admin
    DeliverySetting.current.update!(exceptional_available_dates: [])
  end

  test "admin can add an exceptional delivery date" do
    tuesday = Date.new(2026, 10, 6)

    post admin_exceptional_delivery_dates_path, params: { date: tuesday.iso8601 }

    assert_redirected_to admin_delivery_settings_path
    assert DeliverySetting.current.exceptional_date?(tuesday)
  end

  test "adding the same date twice does not create duplicates or error" do
    tuesday = Date.new(2026, 10, 6)
    post admin_exceptional_delivery_dates_path, params: { date: tuesday.iso8601 }

    post admin_exceptional_delivery_dates_path, params: { date: tuesday.iso8601 }

    assert_redirected_to admin_delivery_settings_path
    assert_equal 1, DeliverySetting.current.exceptional_dates.count(tuesday)
  end

  test "an invalid date is rejected cleanly, without a 500 or persisting anything" do
    post admin_exceptional_delivery_dates_path, params: { date: "not-a-date" }

    assert_redirected_to admin_delivery_settings_path
    assert_equal [], DeliverySetting.current.exceptional_dates
  end

  test "a past date is rejected" do
    past_date = Date.current - 5

    post admin_exceptional_delivery_dates_path, params: { date: past_date.iso8601 }

    assert_redirected_to admin_delivery_settings_path
    assert_not DeliverySetting.current.exceptional_date?(past_date)
  end

  test "admin can remove an exceptional delivery date" do
    tuesday = Date.new(2026, 10, 6)
    DeliverySetting.current.add_exceptional_date!(tuesday)

    delete admin_exceptional_delivery_date_path(tuesday.iso8601)

    assert_redirected_to admin_delivery_settings_path
    assert_not DeliverySetting.current.exceptional_date?(tuesday)
  end

  test "removing a date that isn't currently an exception is a harmless no-op" do
    tuesday = Date.new(2026, 10, 6)

    delete admin_exceptional_delivery_date_path(tuesday.iso8601)

    assert_redirected_to admin_delivery_settings_path
    assert_not DeliverySetting.current.exceptional_date?(tuesday)
  end

  test "removing an exceptional date makes that date unavailable again" do
    tuesday = Date.new(2026, 10, 6)
    DeliverySetting.current.add_exceptional_date!(tuesday)
    assert DeliveryDateValidator.available?(tuesday, now: Time.zone.local(2026, 10, 5, 20, 0, 0))

    delete admin_exceptional_delivery_date_path(tuesday.iso8601)

    assert_not DeliveryDateValidator.available?(tuesday, now: Time.zone.local(2026, 10, 5, 20, 0, 0))
  end
end
