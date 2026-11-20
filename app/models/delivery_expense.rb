# Gasto pagado con el efectivo de un recorrido (Repartos R4, decisión D2: nunca con dinero
# propio ni con reintegros). Descuenta del efectivo a entregar. Pasa a Administración como
# Expense (con su pago en efectivo) UNA sola vez, al confirmar el cierre (expense_id único).
#
# Nunca se borra ni se edita: corregir = anular con motivo y crear uno nuevo (replaces).
# admin_exception: gasto que supera el efectivo disponible, registrado por administración con
# confirmación explícita y motivo (el repartidor no puede).
class DeliveryExpense < ApplicationRecord
  QUICK_CONCEPTS = ["Nafta", "Estacionamiento", "Peaje", "Insumos"].freeze

  belongs_to :delivery_route, inverse_of: :expenses
  belongs_to :created_by, class_name: "User"
  belongs_to :voided_by, class_name: "User", optional: true
  belongs_to :replaces, class_name: "DeliveryExpense", optional: true
  belongs_to :expense, optional: true
  has_one :replacement, class_name: "DeliveryExpense", foreign_key: :replaces_id, inverse_of: :replaces

  validates :concept, presence: true, length: { maximum: 80 }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :notes, length: { maximum: 500 }
  validates :exception_reason, presence: true, if: :admin_exception?
  validates :void_reason, presence: true, if: :voided?

  scope :not_voided, -> { where(voided_at: nil) }

  before_update :only_voiding_or_posting_can_change
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Los gastos no se borran: se corrigen con motivo." }

  def voided?
    voided_at.present?
  end

  private

  def only_voiding_or_posting_can_change
    allowed = %w[voided_at voided_by_id void_reason expense_id updated_at]
    return if (changed - allowed).empty?

    raise ActiveRecord::ReadOnlyRecord, "Un gasto registrado no se modifica: se corrige con motivo."
  end
end
