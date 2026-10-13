# Pago de un pedido minorista. Cuenta propia: no usa Payment ni CustomerPayment ni la cuenta
# corriente mayorista. Nunca se borra: se anula con motivo (voided_at / void_reason) y deja de
# contar en el saldo, conservando el registro para auditoría.
class RetailOrderPayment < ApplicationRecord
  belongs_to :retail_order, inverse_of: :retail_order_payments
  belongs_to :user, optional: true
  belongs_to :voided_by, class_name: "User", optional: true

  scope :active, -> { where(voided_at: nil) }

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: RetailOrder::MAX_CENTS }
  validates :paid_at, presence: true
  validates :payment_method, inclusion: { in: RetailOrder::PAYMENT_METHODS }
  validates :notes, length: { maximum: 1000 }, allow_blank: true
  validates :void_reason, presence: true, if: :voided?

  before_destroy { throw :abort }

  def voided?
    voided_at.present?
  end

  def payment_method_label
    RetailOrder::PAYMENT_METHOD_LABELS[payment_method] || payment_method
  end
end
