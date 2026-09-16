require "test_helper"
require "bigdecimal"

class Measurement::UnitConverterTest < ActiveSupport::TestCase
  test "kg to g" do
    assert_equal BigDecimal("500"), Measurement::UnitConverter.convert(0.5, from: "kg", to: "g")
  end

  test "g to kg" do
    assert_equal BigDecimal("0.5"), Measurement::UnitConverter.convert(500, from: "g", to: "kg")
  end

  test "l to ml" do
    assert_equal BigDecimal("250"), Measurement::UnitConverter.convert(0.25, from: "l", to: "ml")
  end

  test "ml to l" do
    assert_equal BigDecimal("0.25"), Measurement::UnitConverter.convert(250, from: "ml", to: "l")
  end

  test "cc and ml are equivalent (1000 cc = 1 l)" do
    assert_equal BigDecimal("1"), Measurement::UnitConverter.convert(1000, from: "cc", to: "l")
    assert_equal BigDecimal("1000"), Measurement::UnitConverter.convert(1, from: "l", to: "cc")
    assert_equal BigDecimal("1"), Measurement::UnitConverter.convert(1, from: "cc", to: "ml")
  end

  test "converting a unit to itself returns the same quantity" do
    assert_equal BigDecimal("25"), Measurement::UnitConverter.convert(25, from: "kg", to: "kg")
  end

  test "incompatible dimensions are rejected with a clear error: mass vs volume" do
    error = assert_raises(Measurement::UnitConverter::IncompatibleUnitsError) do
      Measurement::UnitConverter.convert(1, from: "kg", to: "l")
    end
    assert_match(/kg/, error.message)
    assert_match(/l/, error.message)
  end

  test "incompatible dimensions are rejected: mass vs count" do
    assert_raises(Measurement::UnitConverter::IncompatibleUnitsError) do
      Measurement::UnitConverter.convert(1, from: "kg", to: "un")
    end
  end

  test "incompatible dimensions are rejected: count vs mass" do
    assert_raises(Measurement::UnitConverter::IncompatibleUnitsError) do
      Measurement::UnitConverter.convert(1, from: "un", to: "g")
    end
  end

  test "incompatible dimensions are rejected: time vs mass" do
    assert_raises(Measurement::UnitConverter::IncompatibleUnitsError) do
      Measurement::UnitConverter.convert(1, from: "min", to: "kg")
    end
  end

  test "the converter knows about the time dimension even though nothing uses it yet" do
    assert_equal :time, Measurement::UnitConverter.dimension_of("min")
    assert_equal BigDecimal("45"), Measurement::UnitConverter.convert(45, from: "min", to: "min")
  end

  test "unknown units raise a clear error instead of silently converting" do
    assert_raises(Measurement::UnitConverter::UnknownUnitError) do
      Measurement::UnitConverter.convert(1, from: "kg", to: "lb")
    end
  end

  test "compatible? reports true only within the same dimension" do
    assert Measurement::UnitConverter.compatible?("kg", "g")
    assert Measurement::UnitConverter.compatible?("l", "cc")
    assert_not Measurement::UnitConverter.compatible?("kg", "l")
    assert_not Measurement::UnitConverter.compatible?("un", "kg")
    assert_not Measurement::UnitConverter.compatible?("kg", "invented")
  end

  test "handles decimal quantities without float rounding errors" do
    # 0.1 + 0.2 en Float da 0.30000000000000004 — con BigDecimal no.
    result = Measurement::UnitConverter.convert("0.1", from: "kg", to: "g")
    assert_equal BigDecimal("100"), result

    result = Measurement::UnitConverter.convert("333.333", from: "g", to: "kg")
    assert_equal BigDecimal("0.333333"), result
  end
end
