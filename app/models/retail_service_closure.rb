# Fecha puntual sin servicio en la tienda minorista: sin retiro, sin envío o sin ninguno ("all").
# No cambia los días habituales. Es independiente de BlockedDate (mayorista): bloquear una fecha
# acá no afecta al reparto mayorista ni al revés.
class RetailServiceClosure < ApplicationRecord
  SERVICES = %w[all pickup delivery].freeze
  SERVICE_LABELS = { "all" => "Retiro y envío", "pickup" => "Solo retiro", "delivery" => "Solo envío" }.freeze

  belongs_to :created_by, class_name: "User", optional: true

  before_validation { self.reason = reason.to_s.squish.presence }

  validates :date, presence: true
  validates :service, inclusion: { in: SERVICES }
  validates :date, uniqueness: { scope: :service, message: "ya está bloqueada para esa modalidad" }
  validates :reason, length: { maximum: 150 }, allow_nil: true

  scope :upcoming, ->(today) { where("date >= ?", today).order(:date, :service) }
  scope :affecting, ->(service) { where(service: ["all", service.to_s]) }

  def service_label
    SERVICE_LABELS[service]
  end
end
