# Fecha puntual sin entregas (ej. el sábado 07/11/2026 que no se trabaja): bloquea ese día para
# los clientes aunque caiga en un día habitual de reparto. No cambia los días habituales ni
# afecta al admin, que puede cargar pedidos en cualquier fecha (Order#created_by_admin?).
# Es la fuente única que consultan DeliveryDateValidator (backend) y el calendario del cliente.
class BlockedDate < ApplicationRecord
  DEFAULT_REASON = "Fecha bloqueada manualmente".freeze

  scope :active, -> { where(active: true) }

  def self.for_date(date)
    active.where(date: date.to_date).order(:id).first
  end

  # Fechas bloqueadas desde hoy, para deshabilitarlas en el calendario del cliente.
  def self.upcoming_dates(today = Date.current)
    active.where("date >= ?", today).distinct.order(:date).pluck(:date)
  end

  def message
    reason.presence || DEFAULT_REASON
  end
end
