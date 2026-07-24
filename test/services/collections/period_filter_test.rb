require "test_helper"

class Collections::PeriodFilterTest < ActiveSupport::TestCase
  test "defaults to this_month when no period is given" do
    filter = Collections::PeriodFilter.new(period: nil)

    assert_equal "this_month", filter.period
    assert_equal Date.current.beginning_of_month, filter.from
    assert_equal Date.current.end_of_month, filter.to
  end

  test "defaults to this_month when an invalid period is given" do
    filter = Collections::PeriodFilter.new(period: "not_a_real_period")

    assert_equal "this_month", filter.period
  end

  test "last_7_days resolves to a 7-day range ending today" do
    filter = Collections::PeriodFilter.new(period: "last_7_days")

    assert_equal Date.current, filter.to
    assert_equal Date.current - 6.days, filter.from
  end

  test "last_month resolves to the full previous calendar month" do
    filter = Collections::PeriodFilter.new(period: "last_month")

    expected_month = 1.month.ago.to_date
    assert_equal expected_month.beginning_of_month, filter.from
    assert_equal expected_month.end_of_month, filter.to
  end

  test "custom uses the given from/to dates" do
    filter = Collections::PeriodFilter.new(period: "custom", from: "2026-01-01", to: "2026-01-15")

    assert_equal Date.new(2026, 1, 1), filter.from
    assert_equal Date.new(2026, 1, 15), filter.to
  end

  test "custom falls back to sensible defaults when dates are blank or invalid" do
    filter = Collections::PeriodFilter.new(period: "custom", from: "", to: "not-a-date")

    assert_equal Date.current.beginning_of_month, filter.from
    assert_equal Date.current, filter.to
  end

  test "label returns the Spanish label for the resolved period" do
    assert_equal "Este mes", Collections::PeriodFilter.new(period: "this_month").label
    assert_equal "Últimos 7 días", Collections::PeriodFilter.new(period: "last_7_days").label
    assert_equal "Mes anterior", Collections::PeriodFilter.new(period: "last_month").label
    assert_equal "Personalizado", Collections::PeriodFilter.new(period: "custom").label
  end
end
