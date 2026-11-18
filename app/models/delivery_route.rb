# Recorrido de reparto de un día (Repartos R2). Lo arma administración con pedidos mayoristas
# reales (DeliveryStop) y paradas manuales. Armar o editar un recorrido NUNCA modifica pedidos,
# pagos, stock ni cuentas corrientes: solo estas tablas. Todo cambio queda en DeliveryEvent.
# Ver docs/REPARTOS_Y_RENDICIONES.md y DeliveryRoutes::*.
class DeliveryRoute < ApplicationRecord
  STATUSES = %w[draft in_progress submitted confirmed].freeze
  STATUS_LABELS = {
    "draft" => "Preparando", "in_progress" => "En reparto",
    "submitted" => "Rendición enviada", "confirmed" => "Rendición confirmada"
  }.freeze

  belongs_to :driver, class_name: "User", optional: true
  belongs_to :created_by, class_name: "User"
  has_many :stops, -> { order(:position, :id) }, class_name: "DeliveryStop", inverse_of: :delivery_route, dependent: :restrict_with_exception
  has_many :events, -> { order(:created_at, :id) }, class_name: "DeliveryEvent", inverse_of: :delivery_route, dependent: :restrict_with_exception

  validates :date, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :driver_must_be_a_driver

  scope :recent_first, -> { order(date: :desc, id: :desc) }

  def active_stops
    stops.active
  end

  def removed_stops
    stops.removed
  end

  def status_label
    STATUS_LABELS.fetch(status, status)
  end

  # En R2 solo existe "Preparando": administración puede editarlo libremente (con historial).
  def editable?
    status == "draft"
  end

  # Pedidos mayoristas de la fecha (sin cancelados) que no están en ninguna parada vigente ni
  # fueron quitados de este recorrido: los que nadie tiene asignados.
  def unassigned_orders
    taken = DeliveryStop.where.not(order_id: nil).where(removed_at: nil).select(:order_id)
    removed_here = stops.removed.where.not(order_id: nil).select(:order_id)
    Order.for_delivery_date(date).where.not(id: taken).where.not(id: removed_here)
         .includes(:customer).joins(:customer).order(Arel.sql("lower(customers.name)"), :id)
  end

  private

  def driver_must_be_a_driver
    errors.add(:driver, "tiene que ser un usuario repartidor") if driver && !driver.driver?
  end
end
