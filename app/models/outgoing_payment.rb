# Pago realizado a un proveedor (o por un gasto sin proveedor). Se registra UNA vez, se
# imputa a una o más obligaciones (OutgoingPaymentApplication) y lo no imputado es un
# ANTICIPO del proveedor. Nunca se borra: se anula conservando el registro.
class OutgoingPayment < ApplicationRecord
  include HasAdministrationAttachments

  METHODS = {
    "cash" => "Efectivo", "bank_transfer" => "Transferencia bancaria", "debit_card" => "Tarjeta de débito",
    "credit_card" => "Tarjeta de crédito", "check" => "Cheque", "other" => "Otro"
  }.freeze

  belongs_to :supplier, optional: true
  belongs_to :user
  belongs_to :voided_by, class_name: "User", optional: true
  has_many :applications, class_name: "OutgoingPaymentApplication", dependent: :restrict_with_exception

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :paid_on, presence: true
  validates :payment_method, inclusion: { in: METHODS.keys }
  validates :reference, length: { maximum: 200 }
  validates :note, length: { maximum: 1000 }
  validates :void_reason, presence: true, if: :voided?

  scope :active, -> { where(voided_at: nil) }

  def voided?
    voided_at.present?
  end

  def method_label
    METHODS[payment_method]
  end

  def applied_cents
    applications.active.sum(:amount_cents)
  end

  # Anticipo: lo que todavía no se imputó a ninguna obligación. Un pago anulado no deja nada.
  def unapplied_cents
    voided? ? 0 : amount_cents - applied_cents
  end
end
