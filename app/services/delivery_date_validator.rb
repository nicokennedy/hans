class DeliveryDateValidator
  UNAVAILABLE_WEEKDAYS = [0, 2, 4].freeze # domingo, martes, jueves

  # Nombres en plural para el mensaje de error, en el orden habitual de la
  # semana (lunes a domingo) — no el orden numérico de wday (que arranca en
  # domingo=0), para que el mensaje se lea "martes, jueves ni domingos" y
  # no "domingos, martes ni jueves".
  WEEKDAY_DISPLAY_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze
  WEEKDAY_PLURAL_NAMES = {
    0 => "domingos",
    1 => "lunes",
    2 => "martes",
    3 => "miércoles",
    4 => "jueves",
    5 => "viernes",
    6 => "sábados"
  }.freeze

  def self.available?(date, now: Time.zone.now)
    new(date, now: now).available?
  end

  def self.reason(date, now: Time.zone.now)
    new(date, now: now).reason
  end

  def self.unavailable_weekdays
    UNAVAILABLE_WEEKDAYS
  end

  def initialize(date, now: Time.zone.now)
    @date = date.to_date
    @now = now.in_time_zone
    @settings = DeliverySetting.current
  end

  def available?
    reason.nil?
  end

  def reason
    return "Fecha bloqueada manualmente" if blocked_date?
    return unavailable_weekday_message if unavailable_weekday?
    return "Cerró el horario de pedidos para esta fecha" if cutoff_passed?

    nil
  end

  private

  attr_reader :date, :now, :settings

  def blocked_date?
    BlockedDate.where(date: date, active: true).exists?
  end

  def unavailable_weekday?
    settings.unavailable_weekdays.include?(date.wday)
  end

  # Mensaje derivado de la misma lista de días bloqueados (nunca hardcodea
  # "martes, jueves ni domingos" como texto fijo), así que si el conjunto de
  # días bloqueados cambia de nuevo en el futuro, el mensaje se actualiza
  # solo, sin tocar este método.
  def unavailable_weekday_message
    names = WEEKDAY_DISPLAY_ORDER
      .select { |wday| settings.unavailable_weekdays.include?(wday) }
      .map { |wday| WEEKDAY_PLURAL_NAMES[wday] }

    "No realizamos entregas los #{to_spanish_list(names)}. Elegí otra fecha."
  end

  def to_spanish_list(items)
    return items.first if items.size <= 1

    "#{items[0..-2].join(', ')} ni #{items.last}"
  end

  def cutoff_passed?
    cutoff_time = date.in_time_zone.beginning_of_day
    now >= cutoff_time
  end
end
