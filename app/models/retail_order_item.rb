# Ítem de un pedido minorista. Con product_id es un producto de catálogo (entra a producción y
# descuenta stock por Stock::DispatchReconciler); sin product_id es un producto manual:
# descripción libre, aparece en producción como "PRODUCTOS ESPECIALES" y NO toca stock ni recetas.
# El precio unitario siempre es manual (no se toma del precio mayorista ni se modifica el
# producto). product_name_snapshot guarda el nombre al cargar. Importes en centavos enteros.
class RetailOrderItem < ApplicationRecord
  belongs_to :retail_order, inverse_of: :retail_order_items
  belongs_to :product, optional: true

  MAX_QUANTITY = 100_000

  validates :product_name_snapshot, presence: true, length: { maximum: 200 }
  validates :description, presence: true, length: { maximum: 200 }, unless: :product_id?
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: MAX_QUANTITY }
  validates :unit_price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: RetailOrder::MAX_CENTS }
  validates :line_total_cents, numericality: { only_integer: true, less_than_or_equal_to: RetailOrder::MAX_CENTS }

  scope :catalog, -> { where.not(product_id: nil) }
  scope :manual, -> { where(product_id: nil) }

  before_validation :set_derived_fields

  def catalog?
    product_id.present?
  end

  def manual?
    !catalog?
  end

  def display_name
    product_name_snapshot.presence || description
  end

  private

  def set_derived_fields
    if catalog?
      self.product_name_snapshot = product&.name if product_name_snapshot.blank?
    else
      self.description = description.to_s.squish.presence
      self.product_name_snapshot = description
    end
    self.line_total_cents = quantity.to_i * unit_price_cents.to_i
  end
end
