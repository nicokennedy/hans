# Parada de un recorrido: un pedido mayorista real (kind "order") o una parada manual
# (retiro de insumos, compra, gestión u otra). Quitar una parada no la borra: se marca
# removed_at con quién y por qué, y el pedido original no se toca. Un pedido solo puede estar
# en una parada vigente (índice único parcial en la base).
class DeliveryStop < ApplicationRecord
  KINDS = %w[order supplies_pickup purchase errand other].freeze
  MANUAL_KINDS = {
    "supplies_pickup" => "Retiro de insumos", "purchase" => "Compra",
    "errand" => "Gestión", "other" => "Otra parada"
  }.freeze
  REMOVAL_KINDS = {
    "owners_deliver" => "Lo entregan las dueñas", "rescheduled" => "Pasa a otro día", "other" => "Otro motivo",
    "transferred" => "Pasó a otro repartidor"
  }.freeze
  # Motivos que administración elige al quitar una parada ("transferred" lo pone el sistema).
  MANUAL_REMOVAL_KINDS = REMOVAL_KINDS.except("transferred").freeze

  DELIVERY_STATUSES = %w[pending delivered not_delivered done].freeze
  DELIVERY_STATUS_LABELS = { "pending" => "Falta", "delivered" => "Entregado", "not_delivered" => "No entregado", "done" => "Hecho" }.freeze
  NOT_DELIVERED_REASONS = ["Estaba cerrado", "No lo quisieron recibir", "No llegué", "Otro motivo"].freeze

  belongs_to :delivery_route, inverse_of: :stops
  belongs_to :order, optional: true
  belongs_to :customer, optional: true
  belongs_to :removed_by, class_name: "User", optional: true
  belongs_to :delivery_recorded_by, class_name: "User", optional: true

  validates :kind, inclusion: { in: KINDS }
  validates :position, numericality: { only_integer: true, greater_than: 0 }
  validates :order, presence: true, if: :order?
  validates :order, absence: true, unless: :order?
  validates :title, presence: true, length: { maximum: 120 }, unless: :order?
  validates :address, length: { maximum: 200 }
  validates :notes, length: { maximum: 1000 }
  validates :removal_kind, inclusion: { in: REMOVAL_KINDS.keys }, if: :removed?
  validates :removal_reason, presence: true, if: -> { removed? && removal_kind == "other" }
  validates :delivery_status, inclusion: { in: DELIVERY_STATUSES }
  validates :delivery_status, exclusion: { in: %w[delivered], message: "no aplica a una parada manual" }, unless: :order?
  validates :not_delivered_reason, presence: true, if: -> { delivery_status == "not_delivered" }

  scope :active, -> { where(removed_at: nil) }
  scope :removed, -> { where.not(removed_at: nil) }
  scope :pending_delivery, -> { where(delivery_status: "pending") }

  def order?
    kind == "order"
  end

  def manual?
    !order?
  end

  def removed?
    removed_at.present?
  end

  # Entregado (pedido) o hecho (parada manual): ya no se mueve ni se quita.
  def completed?
    %w[delivered done].include?(delivery_status)
  end

  def delivery_status_label
    DELIVERY_STATUS_LABELS.fetch(delivery_status, delivery_status)
  end

  def kind_label
    order? ? "Pedido" : MANUAL_KINDS.fetch(kind, kind)
  end

  def removal_label
    REMOVAL_KINDS.fetch(removal_kind, removal_kind)
  end

  def display_name
    order? ? order.customer.name.to_s.strip : title
  end

  # Dirección vigente: la del cliente (siempre la actualizada) o la cargada en la parada manual.
  def address_line
    if order?
      c = order.customer
      [c.address, c.address_unit].map { |v| v.to_s.strip.presence }.compact.join(" · ").presence
    else
      address.presence
    end
  end

  def instructions
    order? ? order.customer.delivery_instructions.presence : notes.presence
  end

  def google_maps_url
    if order?
      order.customer.google_maps_url
    elsif address.present?
      "https://www.google.com/maps/search/?api=1&query=#{ERB::Util.url_encode([address, 'Mar del Plata', 'Argentina'].join(', '))}"
    end
  end

  def missing_address?
    address_line.blank?
  end

  # Avisos sobre el pedido original, que pudo cambiar después de armar el recorrido.
  def order_warnings
    return [] unless order?

    warnings = []
    warnings << "El pedido está cancelado." if order.canceled?
    warnings << "La fecha de entrega del pedido cambió al #{I18n.l(order.delivery_date, format: '%d/%m')}." if order.delivery_date != delivery_route.date
    warnings
  end
end
