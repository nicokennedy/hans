require "test_helper"

class DeliverySettingTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  fixtures :delivery_settings

  setup do
    DeliverySetting.current.update!(exceptional_available_dates: [])
  end

  test "current is a singleton row, created on first access with the expected defaults" do
    setting = DeliverySetting.current

    assert_equal DeliveryDateValidator.unavailable_weekdays, setting.unavailable_weekdays
  end

  test "exceptional_dates is empty by default" do
    assert_equal [], DeliverySetting.current.exceptional_dates
  end

  test "add_exceptional_date! persists a Date and makes exceptional_date? true for it" do
    date = Date.new(2026, 10, 6)
    setting = DeliverySetting.current

    setting.add_exceptional_date!(date)

    assert setting.exceptional_date?(date)
    assert_includes DeliverySetting.current.reload.exceptional_dates, date
  end

  test "add_exceptional_date! is idempotent — adding the same date twice does not duplicate it" do
    date = Date.new(2026, 10, 6)
    setting = DeliverySetting.current

    setting.add_exceptional_date!(date)
    setting.add_exceptional_date!(date)

    assert_equal 1, setting.reload.exceptional_dates.count(date)
  end

  test "add_exceptional_date! accepts a Date, a Time, or a parseable string equally" do
    setting = DeliverySetting.current

    setting.add_exceptional_date!(Date.new(2026, 10, 6))
    setting.add_exceptional_date!(Time.zone.local(2026, 10, 6, 15, 0, 0))

    assert_equal 1, setting.reload.exceptional_dates.count(Date.new(2026, 10, 6))
  end

  test "remove_exceptional_date! removes a previously added date" do
    date = Date.new(2026, 10, 6)
    setting = DeliverySetting.current
    setting.add_exceptional_date!(date)

    setting.remove_exceptional_date!(date)

    assert_not setting.exceptional_date?(date)
    assert_not_includes DeliverySetting.current.reload.exceptional_dates, date
  end

  test "remove_exceptional_date! on a date that was never added is a harmless no-op" do
    date = Date.new(2026, 10, 6)
    setting = DeliverySetting.current

    assert_nothing_raised { setting.remove_exceptional_date!(date) }
    assert_not setting.exceptional_date?(date)
  end

  test "exceptional_date? is false for a date never added as an exception" do
    setting = DeliverySetting.current
    setting.add_exceptional_date!(Date.new(2026, 10, 6))

    assert_not setting.exceptional_date?(Date.new(2026, 10, 13))
  end
end
