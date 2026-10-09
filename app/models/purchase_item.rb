class PurchaseItem < ApplicationRecord
  UNITS = (RawMaterial::PURCHASE_UNITS + %w[docena caja bolsa paquete bandeja pack]).freeze
  UNIT_LABELS = { "l" => "litros", "un" => "unidades" }.freeze

  belongs_to :purchase, inverse_of: :items
  # ETAPA 2 (no operativo): vínculo opcional con la materia prima que se compró. Hoy nadie
  # lo lee ni lo escribe, y nada de esta tabla modifica costos ni stock de materias primas.
  belongs_to :raw_material, optional: true

  before_validation :compute_subtotal

  validates :description, presence: true, length: { maximum: 200 }
  validates :quantity, numericality: { greater_than: 0 }
  validates :unit, inclusion: { in: UNITS }
  validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  def self.unit_label(unit)
    UNIT_LABELS[unit] || unit
  end

  private

  def compute_subtotal
    self.subtotal_cents = Finance::Money.line_subtotal_cents(quantity, unit_price_cents) if quantity && unit_price_cents
  end
end
