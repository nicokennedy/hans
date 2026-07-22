# app/models/payment.rb
class Payment < ApplicationRecord
  belongs_to :order

  enum :payment_method, Order.payment_method_selecteds

  PAYMENT_METHOD_LABELS = {
    "cash_on_delivery" => "Efectivo contra entrega",
    "cash_later" => "Cuenta corriente",
    "bank_transfer" => "Transferencia bancaria"
  }.freeze

  validates :amount_cents, numericality: { greater_than: 0 }
  validates :paid_at, presence: true
  validates :payment_method, presence: true
  validate :amount_does_not_exceed_order_balance

  after_save :recalculate_order_payment_state
  after_destroy :recalculate_order_payment_state

  def amount
    amount_cents.to_i / 100
  end

  def amount=(value)
    self.amount_cents = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  def payment_method_label
    PAYMENT_METHOD_LABELS[payment_method] || payment_method
  end

  private

  def amount_does_not_exceed_order_balance
    return if order.blank? || amount_cents.blank?

    other_payments_total = order.payments.where.not(id: id).sum(:amount_cents)

    if other_payments_total + amount_cents.to_i > order.total_cents.to_i
      errors.add(:amount_cents, "supera el saldo pendiente del pedido")
    end
  end

  def recalculate_order_payment_state
    order.recalculate_payment_state!
  end
end
