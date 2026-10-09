# Compra de mercadería a un proveedor, con ítems. Genera UNA obligación (la deuda). En
# esta etapa NO toca stock, materias primas, recetas ni costos: los ítems solo se
# registran (con precio, cantidad y unidad) para poder vincularlos más adelante.
class Purchase < ApplicationRecord
  include HasAdministrationAttachments

  has_one :obligation, as: :source, dependent: :restrict_with_exception
  has_many :items, -> { order(:position, :id) }, class_name: "PurchaseItem", dependent: :destroy, inverse_of: :purchase, autosave: true

  validates :discount_cents, :taxes_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :adjustments_cents, numericality: { only_integer: true }
  validate :total_must_be_positive

  # Total del comprobante = ítems − descuento + impuestos ± otros ajustes (centavos exactos).
  def total_cents
    subtotal_cents.to_i - discount_cents.to_i + taxes_cents.to_i + adjustments_cents.to_i
  end

  def recalculate_subtotal
    self.subtotal_cents = items.reject(&:marked_for_destruction?).sum { |item| item.subtotal_cents.to_i }
  end

  private

  def total_must_be_positive
    errors.add(:base, "El total de la compra debe ser mayor a cero") unless total_cents.positive?
  end
end
