# Reglas de retiro y envío de la tienda minorista (Etapa 3). Independientes del reparto mayorista.
#  - RetailFulfillment::Calendar: qué fechas están habilitadas para cada modalidad.
#  - RetailFulfillment::Quote: valida la elección del cliente y calcula envío y total en el servidor.
#  - RetailFulfillment::Options: todo lo que necesita el checkout de la tienda pública para mostrar
#    modalidades, fechas, franjas y zonas.
module RetailFulfillment
  # Las fechas se cuentan en el calendario de Argentina, sea cual sea la zona del servidor.
  TIME_ZONE = "America/Argentina/Buenos_Aires".freeze
  # Hasta cuántos días hacia adelante se puede elegir una fecha.
  HORIZON_DAYS = 90

  SERVICE_NAMES = {
    "pickup" => "Retiro por zona Plaza del Agua",
    "delivery" => "Envío a domicilio"
  }.freeze

  # Cómo se nombra la franja en cada modalidad (nunca un turno exacto).
  WINDOW_NAMES = { "pickup" => "Horario de retiro", "delivery" => "Franja de entrega" }.freeze

  DAY_NAMES = %w[domingo lunes martes miércoles jueves viernes sábado].freeze

  def self.service_name(service)
    SERVICE_NAMES[service.to_s]
  end

  def self.today(now = Time.current)
    now.in_time_zone(TIME_ZONE).to_date
  end

  # "sábados", "lunes"
  def self.day_plural(date)
    name = DAY_NAMES[date.wday]
    name.end_with?("s") ? name : "#{name}s"
  end

  # "miércoles 11/11"
  def self.format_date(date)
    "#{DAY_NAMES[date.wday]} #{date.strftime('%d/%m')}"
  end
end
