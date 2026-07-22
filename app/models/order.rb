# app/models/order.rb
class Order < ApplicationRecord
  belongs_to :customer
  has_many :order_items, dependent: :destroy
  has_many :order_events, dependent: :destroy
  has_many :payments, dependent: :destroy

  enum :status, {
    received: "received",
    confirmed: "confirmed",
    in_production: "in_production",
    ready: "ready",
    delivered: "delivered",
    canceled: "canceled",
    needs_review: "needs_review"
  }, default: "received"

  enum :payment_status, {
    pending: "pending",
    partial: "partial",
    paid: "paid"
  }, default: "pending"

  enum :payment_method_selected, {
    cash_on_delivery: "cash_on_delivery",
    cash_later: "cash_later",
    bank_transfer: "bank_transfer"
  }

  STATUS_LABELS = {
    "received" => "Recibido",
    "confirmed" => "Confirmado",
    "in_production" => "En producción",
    "ready" => "Listo",
    "delivered" => "Entregado",
    "canceled" => "Cancelado",
    "needs_review" => "Necesita revisión"
  }.freeze

  PAYMENT_STATUS_LABELS = {
    "pending" => "Pendiente",
    "partial" => "Pago parcial",
    "paid" => "Pagado"
  }.freeze

  validates :delivery_date, presence: true
  validates :status, :payment_status, presence: true
  validate :delivery_date_must_be_available, on: :create, unless: :created_by_admin?
  validate :must_have_order_items, on: :update

  scope :not_canceled, -> { where.not(status: "canceled") }

  before_validation :set_defaults
  before_save :recalculate_total

  def status_label
    STATUS_LABELS[status] || status
  end

  def payment_status_label
    PAYMENT_STATUS_LABELS[payment_status] || payment_status
  end

  def balance_due_cents
    total_cents.to_i - amount_paid_cents.to_i
  end

  def recalculate_payment_state!
    paid = payments.sum(:amount_cents)
    update_columns(amount_paid_cents: paid, payment_status: derive_payment_status(paid))
  end

  private

  def set_defaults
    self.status ||= "received"
    self.payment_status ||= "pending"
    self.number ||= "HANS-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3).upcase}"
    self.total_cents ||= 0
    self.amount_paid_cents ||= 0
    self.created_by_admin = false if created_by_admin.nil?
  end

  def recalculate_total
    items = new_record? ? order_items : order_items.reload
    self.total_cents = items.sum { |item| item.line_revenue_cents.to_i }
    self.payment_status = derive_payment_status(amount_paid_cents.to_i)
  end

  def derive_payment_status(paid_cents)
    if paid_cents <= 0
      "pending"
    elsif paid_cents < total_cents.to_i
      "partial"
    else
      "paid"
    end
  end

  def must_have_order_items
    errors.add(:base, "El pedido debe tener al menos un producto.") if order_items.reload.empty?
  end

  def delivery_date_must_be_available
    return if delivery_date.blank?

    reason = DeliveryDateValidator.reason(delivery_date)
    errors.add(:delivery_date, reason) if reason.present?
  end
end