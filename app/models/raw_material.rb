require "bigdecimal"

class RawMaterial < ApplicationRecord
  # Todo lo que se puede comprar/costear en esta fase (sin "min": una
  # materia prima nunca se compra en minutos, esa dimensión existe en el
  # conversor para cuando Preparation necesite mano de obra más adelante).
  PURCHASE_UNITS = %w[kg g l ml cc un].freeze

  # base_unit se restringe a la unidad de referencia de cada dimensión
  # (kg/l/un), no a cualquiera de las 6 físicas. Si se permitiera "g" o "ml"
  # como base, dos materias primas de la misma naturaleza (ej. dos harinas)
  # podrían terminar con costos normalizados en unidades distintas (una en
  # $/kg, otra en $/g), lo que hace los costos no comparables entre sí y
  # complica cualquier reporte o receta que las mezcle. No encontré un
  # caso real del negocio que lo justifique, así que V1 prioriza
  # consistencia: siempre kg para masa, l para volumen, un para cantidad.
  CANONICAL_BASE_UNITS = %w[kg l un].freeze

  # restrict_with_error, no delete_all/destroy: el historial es append-only
  # a propósito — borrar una RawMaterial nunca debe llevarse su historial
  # por delante en silencio. Si tiene cost_changes, destroy simplemente
  # falla (mismo patrón que Customer#orders/Category#products). La política
  # de HANS es desactivar (active: false), no eliminar; por ahora ni
  # siquiera existe un endpoint destroy para RawMaterial.
  has_many :cost_changes,
    class_name: "RawMaterialCostChange",
    dependent: :restrict_with_error,
    inverse_of: :raw_material

  validates :name, presence: true
  validates :purchase_price_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :purchase_quantity, presence: true, numericality: { greater_than: 0 }
  validates :purchase_unit, presence: true, inclusion: { in: PURCHASE_UNITS }
  validates :base_unit, presence: true, inclusion: { in: CANONICAL_BASE_UNITS }
  validates :unit_cost_cents, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validate :purchase_unit_compatible_with_base_unit

  before_validation :calculate_unit_cost_cents

  def purchase_price_amount
    purchase_price_cents.to_i / 100
  end

  def purchase_price_amount=(value)
    self.purchase_price_cents = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  def purchase_format
    return nil if purchase_quantity.blank? || purchase_unit.blank?

    "#{format_quantity(purchase_quantity)} #{purchase_unit}"
  end

  private

  def format_quantity(quantity)
    quantity.to_d.to_s("F").sub(/0+\z/, "").sub(/\.\z/, "")
  end

  # Recalculado siempre, nunca leído de params: es la única fuente de
  # verdad. Si el request llegara a mandar un unit_cost_cents manipulado,
  # esta línea lo pisa antes de que la validación/el guardado lo vean.
  def calculate_unit_cost_cents
    self.unit_cost_cents = normalized_unit_cost_cents
  end

  def normalized_unit_cost_cents
    return nil if purchase_price_cents.nil? || purchase_quantity.blank? || purchase_unit.blank? || base_unit.blank?
    return nil unless purchase_quantity.to_d.positive?
    return nil unless Measurement::UnitConverter.compatible?(purchase_unit, base_unit)

    quantity_in_base_unit = Measurement::UnitConverter.convert(purchase_quantity, from: purchase_unit, to: base_unit)
    return nil unless quantity_in_base_unit.positive?

    (BigDecimal(purchase_price_cents.to_s) / quantity_in_base_unit).round.to_i
  end

  def purchase_unit_compatible_with_base_unit
    return if purchase_unit.blank? || base_unit.blank?
    return unless Measurement::UnitConverter.valid_unit?(purchase_unit) && Measurement::UnitConverter.valid_unit?(base_unit)

    unless Measurement::UnitConverter.compatible?(purchase_unit, base_unit)
      errors.add(:base_unit, "no es compatible con la unidad de compra (#{purchase_unit})")
    end
  end
end
