# app/models/payment.rb
class Payment < ApplicationRecord
  belongs_to :order
  # Si viene de un pago de cuenta corriente (CustomerPayment) esta fila es una
  # APLICACIÓN de esa transferencia a este pedido, no un ingreso adicional: el
  # ingreso real es el CustomerPayment. Los pagos individuales por pedido (todos los
  # históricos) tienen customer_payment_id NULL y se comportan exactamente como siempre.
  belongs_to :customer_payment, optional: true
  belongs_to :user, optional: true

  APPLICATION_KINDS = %w[distribution credit].freeze

  # Los pagos anulados se conservan como registro pero no cuentan en el saldo.
  scope :active, -> { where(voided_at: nil) }
  scope :individual, -> { where(customer_payment_id: nil) }

  enum :payment_method, Order.payment_method_selecteds

  # Misma fuente que Order::PAYMENT_METHOD_LABELS — un solo lugar para no
  # duplicar ni desincronizar las etiquetas de método de pago.
  PAYMENT_METHOD_LABELS = Order::PAYMENT_METHOD_LABELS

  validates :amount_cents, numericality: { greater_than: 0 }
  validates :paid_at, presence: true
  validates :payment_method, presence: true
  validates :application_kind, inclusion: { in: APPLICATION_KINDS }, if: :customer_payment_id?
  validates :application_kind, absence: true, unless: :customer_payment_id?
  validate :amount_does_not_exceed_order_balance, unless: :voided?
  before_destroy :protect_account_applications

  after_save :recalculate_order_payment_state
  after_destroy :recalculate_order_payment_state

  def amount
    amount_cents.to_i / 100
  end

  def amount=(value)
    self.amount_cents = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  def voided?
    voided_at.present?
  end

  def individual?
    customer_payment_id.nil?
  end

  def credit_application?
    application_kind == "credit"
  end

  def payment_method_label
    PAYMENT_METHOD_LABELS[payment_method] || payment_method
  end

  private

  def amount_does_not_exceed_order_balance
    return if order.blank? || amount_cents.blank?

    other_payments_total = order.payments.active.where.not(id: id).sum(:amount_cents)

    if other_payments_total + amount_cents.to_i > order.total_cents.to_i
      errors.add(:amount_cents, "supera el saldo pendiente del pedido")
    end
  end

  # Una aplicación de un pago de cuenta corriente no se borra suelta: se anula el pago
  # (o se revierte la aplicación de saldo a favor) desde la cuenta corriente, con
  # motivo. Borrar el pedido entero sigue funcionando como antes.
  def protect_account_applications
    return if individual? || destroyed_by_association

    errors.add(:base, "Este pago es una aplicación de un pago de cuenta corriente: anulalo desde la cuenta corriente del cliente.")
    throw :abort
  end

  def recalculate_order_payment_state
    order.recalculate_payment_state!
  end
end
