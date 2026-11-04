# Pedido minorista: venta manual a un comprador individual (nombre, teléfono y entrega se
# guardan en el propio pedido). Es independiente de los pedidos mayoristas: no tiene Customer,
# no usa Payment / CustomerPayment ni la cuenta corriente. Los productos de catálogo entran a
# producción y a stock por el mismo mecanismo que los mayoristas (Stock::DispatchReconciler);
# los productos manuales solo aparecen en producción (ver RetailOrderItem).
# Los importes son centavos enteros; el estado operativo (status) es independiente del
# estado de pago (payment_status, derivado de los pagos activos).
#
# Confirmación (confirmation_status), independiente de los otros dos: los pedidos que carga el
# equipo (source "manual") nacen confirmados; los de la tienda online (source "store") nacen
# "awaiting" y no cuentan para producción ni stock hasta que alguien los confirma (ver
# .committed y Retail::ChangeConfirmation). Un rechazo es definitivo.
class RetailOrder < ApplicationRecord
  belongs_to :created_by, class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true
  belongs_to :rejected_by, class_name: "User", optional: true
  has_many :retail_order_items, -> { order(:position, :id) }, dependent: :destroy, inverse_of: :retail_order
  has_many :retail_order_payments, -> { order(:paid_at, :id) }, dependent: :restrict_with_error, inverse_of: :retail_order
  has_many :retail_order_status_changes, -> { order(:created_at, :id) }, dependent: :destroy
  has_many :retail_order_confirmation_changes, -> { order(:created_at, :id) }, dependent: :destroy
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
  enum :confirmation_status, { awaiting: "awaiting", confirmed: "confirmed", rejected: "rejected" }, default: "confirmed", prefix: :confirmation
  enum :source, { manual: "manual", store: "store" }, default: "manual", prefix: :source

  # Token no predecible para la futura pantalla pública de confirmación del pedido (nunca el id).
  has_secure_token :public_token, length: 32

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

  CONFIRMATION_STATUS_LABELS = {
    "awaiting" => "Pendiente de confirmación",
    "confirmed" => "Confirmado",
    "rejected" => "Rechazado"
  }.freeze

  SOURCE_LABELS = { "manual" => "Manual", "store" => "Tienda online" }.freeze

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
  validates :request_token, length: { maximum: 100 }, allow_nil: true
  validates :rejection_reason, presence: true, length: { maximum: 1000 }, if: :confirmation_rejected?

  validate :store_orders_start_awaiting, on: :create

  before_validation :normalize_text
  before_validation :stamp_confirmation, on: :create

  scope :not_canceled, -> { where.not(status: "canceled") }
  # ÚNICA condición de "pedido que cuenta" para producción y stock: confirmado y no cancelado.
  # Los pendientes de confirmación y los rechazados nunca suman (ProductionDaySheet,
  # Stock::Availability, Stock::DispatchReconciler la usan; no repetir la condición a mano).
  scope :committed, -> { not_canceled.where(confirmation_status: "confirmed") }
  scope :for_delivery_date, ->(date) { committed.where(delivery_date: date) }
  # Pedidos de la tienda por revisar: visibles para el equipo, fuera de las cantidades.
  scope :awaiting_review, -> { not_canceled.where(confirmation_status: "awaiting") }

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

  def confirmation_status_label
    CONFIRMATION_STATUS_LABELS[confirmation_status]
  end

  def source_label
    SOURCE_LABELS[source]
  end

  # Mismo criterio que .committed, para un pedido ya cargado.
  def committed?
    !canceled? && confirmation_confirmed?
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

  # Un pedido de la tienda nunca puede nacer confirmado: entraría a producción y stock sin que
  # nadie lo revise.
  def store_orders_start_awaiting
    errors.add(:confirmation_status, "de un pedido de la tienda online debe ser Pendiente de confirmación") if source_store? && !confirmation_awaiting?
  end

  # Un pedido creado confirmado (manual) sin fecha de confirmación la toma de su alta: la base
  # exige que todo confirmado tenga fecha (retail_orders_confirmed_has_date).
  def stamp_confirmation
    self.confirmed_at ||= Time.current if confirmation_confirmed?
  end

  def normalize_text
    self.buyer_name = buyer_name.to_s.squish.presence
    self.buyer_phone = buyer_phone.to_s.squish.presence
    self.delivery_time_note = delivery_time_note.to_s.squish.presence
    self.address = address.to_s.squish.presence
    self.notes = notes.to_s.strip.presence
  end
end
