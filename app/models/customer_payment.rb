# Pago recibido de un cliente para su cuenta corriente (ej. una transferencia de
# $300.000 que cancela varios pedidos). Es el INGRESO real: se registra una sola vez.
# Se reparte entre pedidos con filas de Payment (sus "aplicaciones"); lo que no se
# reparte es saldo a favor del cliente. Nunca se borra: se anula conservando el
# registro (ver CustomerAccount::VoidPayment).
class CustomerPayment < ApplicationRecord
  belongs_to :customer
  belongs_to :user
  belongs_to :voided_by, class_name: "User", optional: true
  has_many :applications, class_name: "Payment", foreign_key: :customer_payment_id, inverse_of: :customer_payment, dependent: :restrict_with_exception

  enum :payment_method, Order.payment_method_selecteds

  PAYMENT_METHOD_LABELS = Order::PAYMENT_METHOD_LABELS

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :paid_on, :payment_method, presence: true
  validates :reference, length: { maximum: 200 }
  validates :note, length: { maximum: 1000 }
  validates :void_reason, presence: true, if: :voided?

  scope :active, -> { where(voided_at: nil) }

  def voided?
    voided_at.present?
  end

  def payment_method_label
    PAYMENT_METHOD_LABELS[payment_method] || payment_method
  end

  # Cuánto de este pago ya se aplicó a pedidos (aplicaciones no anuladas).
  def applied_cents
    applications.active.sum(:amount_cents)
  end

  # Saldo a favor que todavía queda de este pago. Un pago anulado no deja crédito.
  def unapplied_cents
    return 0 if voided?

    amount_cents - applied_cents
  end
end
