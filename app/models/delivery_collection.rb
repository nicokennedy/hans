# Cobro en efectivo registrado en un recorrido (Repartos R4). El dinero en sí es un
# CustomerPayment de la cuenta corriente existente (efectivo contraentrega, registrado con
# CustomerAccounts::RegisterPayment): esta fila solo lo vincula con el recorrido, la parada,
# el repartidor y el modo. Así el cobro se cuenta UNA vez en los reportes (el CustomerPayment)
# y se rastrea pago → cliente → pedidos → repartidor → recorrido.
#
#  - mode "allocated": aplicado a los pedidos elegidos; lo que sobra queda como saldo a favor.
#  - mode "unidentified": "No sé a qué pedido corresponde": todo queda como saldo a favor del
#    cliente, marcado "A identificar"; administración lo imputa con "Aplicar saldo a favor".
#
# Nunca se borra ni se edita el importe: una corrección anula este cobro (voided_*, con
# motivo, y anula su CustomerPayment con CustomerAccounts::VoidPayment) y crea uno nuevo que
# apunta a este (replaces).
class DeliveryCollection < ApplicationRecord
  MODES = %w[allocated unidentified].freeze

  belongs_to :delivery_route, inverse_of: :collections
  belongs_to :delivery_stop
  belongs_to :customer
  belongs_to :customer_payment
  belongs_to :created_by, class_name: "User"
  belongs_to :voided_by, class_name: "User", optional: true
  belongs_to :replaces, class_name: "DeliveryCollection", optional: true
  has_one :replacement, class_name: "DeliveryCollection", foreign_key: :replaces_id, inverse_of: :replaces
  has_one_attached :evidence

  validates :mode, inclusion: { in: MODES }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :void_reason, presence: true, if: :voided?

  scope :not_voided, -> { where(voided_at: nil) }

  before_update :only_voiding_can_change
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "Los cobros no se borran: se corrigen con motivo." }

  def voided?
    voided_at.present?
  end

  def unidentified?
    mode == "unidentified"
  end

  # Vigente para la rendición: no corregido y con su pago de cuenta corriente sin anular.
  def counts?
    !voided? && !customer_payment.voided?
  end

  # El pago de cuenta corriente se anuló por fuera de Repartos (desde la cuenta corriente).
  def voided_outside?
    !voided? && customer_payment.voided?
  end

  # { order_id(Integer) => cents }
  def allocation_map
    allocations.to_h.transform_keys(&:to_i)
  end

  def applied_cents
    amount_cents - credit_cents
  end

  private

  def only_voiding_can_change
    allowed = %w[voided_at voided_by_id void_reason updated_at]
    return if (changed - allowed).empty?

    raise ActiveRecord::ReadOnlyRecord, "Un cobro registrado no se modifica: se corrige con motivo."
  end
end
