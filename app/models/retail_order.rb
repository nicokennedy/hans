# Pedido minorista: venta manual a un comprador individual (nombre, teléfono y entrega se
# guardan en el propio pedido). Es independiente de los pedidos mayoristas: no tiene Customer,
# no usa Payment / CustomerPayment ni la cuenta corriente. Los productos de catálogo entran a
# producción y a stock por el mismo mecanismo que los mayoristas (Stock::DispatchReconciler);
# los productos manuales solo aparecen en producción (ver RetailOrderItem).
# Los importes son centavos enteros; el estado operativo (status) es independiente del
# estado de pago (payment_status, derivado de los pagos activos).
class RetailOrder < ApplicationRecord
  belongs_to :created_by, class_name: "User", optional: true
  has_many :retail_order_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :retail_order
  has_many :retail_order_payments, -> { order(:paid_at, :id) }, dependent: :restrict_with_error, inverse_of: :retail_order
  has_many :retail_order_status_changes, -> { order(:created_at, :id) }, dependent: :destroy
  has_many :stock_movements, dependent: :restrict_with_error

  enum :status, {
    pending: "pending",
    in_preparation: "in_preparation",
    ready: "ready",
    delivered: "delivered",
    canceled: "canceled"
  }, default: "pending"

  enum :payment_status, { pending: "pending", partial: "partial", paid: "paid" }, default: "pending", prefix: :payment
  enum :delivery_kind, { pickup: "pickup", delivery: "delivery" }, default: "pickup"

  STATUS_LABELS = {
    "pending" => "Pendiente",
    "in_preparation" => "En preparación",
    "ready" => "Listo",
    "delivered" => "Entregado",
    "canceled" => "Cancelado"
  }.freeze

  PAYMENT_STATUS_LABELS = {
    "pending" => "Pendiente",
    "partial" => "Parcial",
    "paid" => "Pagado"
  }.freeze

  DELIVERY_KIND_LABELS = { "pickup" => "Retiro", "delivery" => "Delivery" }.freeze

  PAYMENT_METHODS = %w[transfer cash_on_delivery openpay].freeze
  PAYMENT_METHOD_LABELS = {
    "transfer" => "Transferencia",
    "cash_on_delivery" => "Efectivo contra entrega",
    "openpay" => "Openpay"
  }.freeze

  MAX_CENTS = 2_000_000_000

  validates :buyer_name, presence: true, length: { maximum: 150 }
  validates :buyer_phone, length: { maximum: 40 }, allow_blank: true
  validates :delivery_time_note, length: { maximum: 120 }, allow_blank: true
  validates :address, length: { maximum: 250 }, allow_blank: true
  validates :notes, length: { maximum: 2000 }, allow_blank: true
  validates :delivery_date, presence: true
  validates :planned_payment_method, inclusion: { in: PAYMENT_METHODS }, allow_blank: true
  validates :shipping_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_CENTS }
  validates :total_cents, numericality: { only_integer: true, less_than_or_equal_to: MAX_CENTS }

  before_validation :normalize_text

  scope :not_canceled, -> { where.not(status: "canceled") }
  scope :for_delivery_date, ->(date) { not_canceled.where(delivery_date: date) }

  def number
    "R-#{id}"
  end

  def status_label
    STATUS_LABELS[status]
  end

  def payment_status_label
    PAYMENT_STATUS_LABELS[payment_status]
  end

  def delivery_kind_label
    DELIVERY_KIND_LABELS[delivery_kind]
  end

  def planned_payment_method_label
    PAYMENT_METHOD_LABELS[planned_payment_method]
  end

  def active_payments
    retail_order_payments.reject(&:voided?)
  end

  # Saldo pendiente: total - pagado. Negativo = hay excedente / saldo a favor del comprador.
  def balance_cents
    total_cents - amount_paid_cents
  end

  def pending_balance_cents
    [balance_cents, 0].max
  end

  def excess_cents
    [-balance_cents, 0].max
  end

  def catalog_items
    retail_order_items.select(&:catalog?)
  end

  def manual_items
    retail_order_items.reject(&:catalog?)
  end

  # Link de WhatsApp al comprador, solo si el teléfono tiene dígitos suficientes.
  def whatsapp_url
    digits = buyer_phone.to_s.gsub(/\D/, "")
    return nil if digits.length < 8

    digits = "54#{digits}" if digits.length <= 11 && !digits.start_with?("54")
    "https://wa.me/#{digits}"
  end

  def self.payment_status_for(total_cents, paid_cents)
    return "paid" if paid_cents >= total_cents
    return "partial" if paid_cents.positive?

    "pending"
  end

  # Recalcula la caché de pagos a partir de los pagos activos. Siempre dentro de una
  # transacción con el pedido bloqueado (ver Retail::*).
  def recalculate_payment_state!
    paid = retail_order_payments.where(voided_at: nil).sum(:amount_cents)
    update_columns(amount_paid_cents: paid, payment_status: self.class.payment_status_for(total_cents, paid), updated_at: Time.current)
  end

  private

  def normalize_text
    self.buyer_name = buyer_name.to_s.squish.presence
    self.buyer_phone = buyer_phone.to_s.squish.presence
    self.delivery_time_note = delivery_time_note.to_s.squish.presence
    self.address = address.to_s.squish.presence
    self.notes = notes.to_s.strip.presence
  end
end
