require "test_helper"

class DeliveryDateValidatorTest < ActiveSupport::TestCase
  self.fixture_table_names = []
  fixtures :delivery_settings, :blocked_dates

  setup do
    BlockedDate.delete_all
  end

  test "Wednesday delivery is available through Tuesday at 23:59" do
    now = Time.zone.local(2026, 7, 14, 23, 59, 59)

    assert DeliveryDateValidator.available?(Date.new(2026, 7, 15), now: now)
  end

  test "Wednesday delivery closes exactly at Wednesday midnight" do
    now = Time.zone.local(2026, 7, 15, 0, 0, 0)

    refute DeliveryDateValidator.available?(Date.new(2026, 7, 15), now: now)
  end

  test "Monday delivery is available on Saturday" do
    now = Time.zone.local(2026, 7, 18, 23, 59, 59)

    assert DeliveryDateValidator.available?(Date.new(2026, 7, 20), now: now)
  end

  test "Monday delivery is available on Sunday" do
    now = Time.zone.local(2026, 7, 19, 23, 59, 59)

    assert DeliveryDateValidator.available?(Date.new(2026, 7, 20), now: now)
  end

  test "Monday delivery closes exactly at Monday midnight" do
    now = Time.zone.local(2026, 7, 20, 0, 0, 0)

    refute DeliveryDateValidator.available?(Date.new(2026, 7, 20), now: now)
  end

  test "Sunday remains unavailable for delivery" do
    now = Time.zone.local(2026, 7, 18, 12, 0, 0)

    refute DeliveryDateValidator.available?(Date.new(2026, 7, 19), now: now)
  end

  test "Tuesday is unavailable for delivery" do
    now = Time.zone.local(2026, 7, 20, 12, 0, 0)
    tuesday = Date.new(2026, 7, 21)
    assert_equal 2, tuesday.wday

    refute DeliveryDateValidator.available?(tuesday, now: now)
  end

  test "Thursday is unavailable for delivery" do
    now = Time.zone.local(2026, 7, 22, 12, 0, 0)
    thursday = Date.new(2026, 7, 23)
    assert_equal 4, thursday.wday

    refute DeliveryDateValidator.available?(thursday, now: now)
  end

  test "the unavailable-weekday message lists Tuesday, Thursday and Sunday in calendar order" do
    now = Time.zone.local(2026, 7, 20, 12, 0, 0)
    tuesday = Date.new(2026, 7, 21)

    assert_equal "No realizamos entregas los martes, jueves ni domingos. Elegí otra fecha.",
      DeliveryDateValidator.reason(tuesday, now: now)
  end

  test "manually blocked date remains unavailable" do
    delivery_date = Date.new(2026, 7, 21)
    BlockedDate.create!(date: delivery_date, active: true)
    now = Time.zone.local(2026, 7, 20, 12, 0, 0)

    refute DeliveryDateValidator.available?(delivery_date, now: now)
  end
end
