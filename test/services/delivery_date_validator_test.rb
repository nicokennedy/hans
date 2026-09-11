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

  test "Friday delivery is available through Thursday at 23:59:59" do
    now = Time.zone.local(2026, 7, 16, 23, 59, 59) # Thursday

    assert DeliveryDateValidator.available?(Date.new(2026, 7, 17), now: now) # Friday
  end

  test "Friday delivery closes exactly at Friday midnight" do
    now = Time.zone.local(2026, 7, 17, 0, 0, 0)

    refute DeliveryDateValidator.available?(Date.new(2026, 7, 17), now: now)
  end

  test "recurring rule: Saturday delivery is available through the previous Friday at 13:59:59 Argentina time" do
    friday = Date.new(2026, 7, 17)
    saturday = Date.new(2026, 7, 18)

    assert DeliveryDateValidator.available?(saturday, now: Time.zone.local(friday.year, friday.month, friday.day, 13, 59, 59))
  end

  test "recurring rule: Saturday delivery closes exactly at the previous Friday 14:00:00 Argentina time" do
    friday = Date.new(2026, 7, 17)
    saturday = Date.new(2026, 7, 18)

    refute DeliveryDateValidator.available?(saturday, now: Time.zone.local(friday.year, friday.month, friday.day, 14, 0, 0))
  end

  test "the Saturday-specific cutoff hour does not affect any other weekday" do
    friday = Date.new(2026, 7, 17)
    monday = Date.new(2026, 7, 20)

    # 14:00 on Friday is exactly the Saturday cutoff instant, but it has no
    # special meaning for Friday itself (already closed since midnight) or
    # for a following Monday (still governed by its own midnight rule).
    refute DeliveryDateValidator.available?(friday, now: Time.zone.local(2026, 7, 17, 14, 0, 0))
    assert DeliveryDateValidator.available?(monday, now: Time.zone.local(2026, 7, 17, 14, 0, 0))
  end

  test "from Friday 14:00 onward, Monday is the next available delivery date" do
    now = Time.zone.local(2026, 7, 17, 14, 0, 1)

    refute DeliveryDateValidator.available?(Date.new(2026, 7, 18), now: now) # Saturday: closed
    refute DeliveryDateValidator.available?(Date.new(2026, 7, 19), now: now) # Sunday: never a delivery day
    assert DeliveryDateValidator.available?(Date.new(2026, 7, 20), now: now) # Monday: available
  end

  test "on Saturday, that same Saturday is closed and the next available delivery is Monday" do
    saturday = Date.new(2026, 7, 18)
    monday = Date.new(2026, 7, 20)
    now = Time.zone.local(2026, 7, 18, 12, 0, 0)

    refute DeliveryDateValidator.available?(saturday, now: now)
    assert DeliveryDateValidator.available?(monday, now: now)
  end

  test "concrete example: Friday 11/09/2026 13:59:59 vs 14:00:00 for Saturday 12/09/2026 delivery, next available Monday 14/09/2026" do
    assert DeliveryDateValidator.available?(Date.new(2026, 9, 12), now: Time.zone.local(2026, 9, 11, 13, 59, 59))
    refute DeliveryDateValidator.available?(Date.new(2026, 9, 12), now: Time.zone.local(2026, 9, 11, 14, 0, 0))
    assert DeliveryDateValidator.available?(Date.new(2026, 9, 14), now: Time.zone.local(2026, 9, 11, 14, 0, 0))
  end
end
