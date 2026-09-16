require "bigdecimal"

module Measurement
  # Conversor mínimo y cerrado entre unidades físicas. No es un ActiveRecord
  # (no hace falta una tabla para un conjunto de 7 unidades que casi nunca
  # cambia) — es un objeto de cálculo puro, mismo espíritu que
  # DeliveryDateValidator: sin estado, sin persistencia, fácil de testear.
  #
  # Cuatro dimensiones cerradas. Solo se puede convertir dentro de la misma
  # dimensión; cruzar dimensiones (ej. kg -> un) siempre es un error, nunca
  # un resultado numérico "aproximado".
  class UnitConverter
    class UnknownUnitError < ArgumentError; end
    class IncompatibleUnitsError < ArgumentError; end

    DIMENSIONS = {
      "kg" => :mass,
      "g" => :mass,
      "l" => :volume,
      "ml" => :volume,
      "cc" => :volume,
      "un" => :count,
      "min" => :time
    }.freeze

    # Factor para llevar 1 unidad a la unidad de referencia de su dimensión
    # (kg para masa, l para volumen, un para cantidad, min para tiempo).
    # BigDecimal siempre, nunca Float, para no arrastrar error de redondeo
    # binario en cálculos de costo.
    FACTORS_TO_REFERENCE = {
      "kg" => BigDecimal("1"),
      "g" => BigDecimal("0.001"),
      "l" => BigDecimal("1"),
      "ml" => BigDecimal("0.001"),
      "cc" => BigDecimal("0.001"),
      "un" => BigDecimal("1"),
      "min" => BigDecimal("1")
    }.freeze

    UNITS = DIMENSIONS.keys.freeze

    def self.valid_unit?(unit)
      UNITS.include?(unit.to_s)
    end

    def self.compatible?(unit_a, unit_b)
      valid_unit?(unit_a) && valid_unit?(unit_b) && DIMENSIONS[unit_a.to_s] == DIMENSIONS[unit_b.to_s]
    end

    def self.dimension_of(unit)
      raise UnknownUnitError, "Unidad desconocida: #{unit.inspect}" unless valid_unit?(unit)

      DIMENSIONS[unit.to_s]
    end

    def self.convert(quantity, from:, to:)
      new.convert(quantity, from: from, to: to)
    end

    def convert(quantity, from:, to:)
      from = from.to_s
      to = to.to_s

      validate_unit!(from)
      validate_unit!(to)

      if DIMENSIONS[from] != DIMENSIONS[to]
        raise IncompatibleUnitsError,
          "No se puede convertir #{from} a #{to}: son dimensiones distintas (#{DIMENSIONS[from]} vs #{DIMENSIONS[to]})"
      end

      amount = BigDecimal(quantity.to_s)
      reference_amount = amount * FACTORS_TO_REFERENCE.fetch(from)
      reference_amount / FACTORS_TO_REFERENCE.fetch(to)
    end

    private

    def validate_unit!(unit)
      raise UnknownUnitError, "Unidad desconocida: #{unit.inspect}" unless self.class.valid_unit?(unit)
    end
  end
end
