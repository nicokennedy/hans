# Recorrido de reparto de un día (Repartos R2). Un repartidor puede tener varios por día. Lo arma administración con pedidos mayoristas
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
  # R4: cobros, gastos y fotos del recorrido; su rendición es independiente de cualquier otro
  # recorrido (también de otro reparto del mismo repartidor ese día).
  has_many :collections, -> { order(:created_at, :id) }, class_name: "DeliveryCollection", inverse_of: :delivery_route, dependent: :restrict_with_exception
  has_many :expenses, -> { order(:spent_at, :id) }, class_name: "DeliveryExpense", inverse_of: :delivery_route, dependent: :restrict_with_exception
  has_many :photos, -> { order(:created_at, :id) }, class_name: "DeliveryPhoto", inverse_of: :delivery_route, dependent: :restrict_with_exception
  belongs_to :submitted_by, class_name: "User", optional: true
  belongs_to :confirmed_by, class_name: "User", optional: true

  validates :date, presence: true
  validates :status, inclusion: { in: STATUSES }
  # R3: todo recorrido nuevo tiene un repartidor responsable, activo. Los recorridos de R2 que
  # quedaron sin repartidor se conservan y se les asigna uno desde su pantalla.
  validates :driver, presence: { message: "es obligatorio: elegí un repartidor" }, on: :create
  validate :driver_must_be_an_active_driver, if: :will_save_change_to_driver_id?

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

  # R4: el repartidor registra entregas, cobros y gastos hasta que envía la rendición.
  def open_for_driver?
    %w[draft in_progress].include?(status)
  end

  def submitted?
    status == "submitted"
  end

  def confirmed?
    status == "confirmed"
  end

  # Administración puede corregir cobros y gastos hasta confirmar el cierre.
  def open_for_admin?
    !confirmed?
  end

  # D8: un recorrido de un día anterior que todavía no envió la rendición.
  def settlement_overdue?(today = Date.current)
    date < today && open_for_driver? && driver_id.present?
  end

  # Pedidos mayoristas de la fecha (sin cancelados) que no están en ninguna parada vigente ni
  # fueron quitados a propósito de algún recorrido de esa fecha: los que nadie tiene asignados.
  def self.unassigned_orders_for(date)
    taken = DeliveryStop.active.where.not(order_id: nil).select(:order_id)
    set_aside = DeliveryStop.removed.where.not(order_id: nil).where.not(removal_kind: "transferred")
                            .joins(:delivery_route).where(delivery_routes: { date: date }).select(:order_id)
    Order.for_delivery_date(date).where.not(id: taken).where.not(id: set_aside)
         .includes(:customer).joins(:customer).order(Arel.sql("lower(customers.name)"), :id)
  end

  def unassigned_orders
    self.class.unassigned_orders_for(date)
  end

  # Otros recorridos de la misma fecha (de cualquier repartidor, también del mismo), para pasarles pedidos.
  def siblings
    DeliveryRoute.where(date: date).where.not(id: id).includes(:driver).order(:id)
  end

  def driver_name
    driver&.display_name || "Sin repartidor"
  end

  # Un repartidor puede tener varios recorridos el mismo día (sale, vuelve a HANS y sale otra
  # vez). Se numeran por orden de creación dentro del día de ese repartidor: Reparto 1, 2...
  # El id no cambia nunca y es lo que identifica al recorrido (y, más adelante, su rendición).
  def number
    return 1 unless persisted?

    @number ||= DeliveryRoute.where(date: date, driver_id: driver_id).where("id <= ?", id).count
  end

  def label
    "Reparto #{number}"
  end

  # "Chiara · Reparto 2": cómo se nombra el recorrido en administración.
  def title
    "#{driver_name} · #{label}"
  end

  # Avance para el repartidor (no es el estado administrativo): sin empezar / en curso / terminado.
  def progress_for(stops)
    return "Rendición enviada" if submitted?
    return "Cerrado" if confirmed?

    done = stops.count { |stop| stop.delivery_status != "pending" }
    if stops.empty? || done.zero?
      "Sin empezar"
    elsif done == stops.size
      "Terminado"
    else
      "En curso: #{done} de #{stops.size}"
    end
  end

  def reload(*)
    @number = nil
    super
  end

  private

  def driver_must_be_an_active_driver
    return unless driver

    errors.add(:driver, "tiene que ser un usuario repartidor") unless driver.driver?
    errors.add(:driver, "tiene el acceso desactivado") unless driver.active?
  end
end
