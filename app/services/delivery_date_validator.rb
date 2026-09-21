class DeliveryDateValidator
  UNAVAILABLE_WEEKDAYS = [0, 2, 4].freeze # domingo, martes, jueves

  # Excepciones puntuales, no una regla recurrente: estas fechas se habilitan
  # como entrega válida por única vez (eventos especiales de HANS) aunque
  # caigan en un día de semana normalmente no habilitado. A propósito es una
  # lista de fechas EXACTAS, no un rango ni un cambio al día de semana — así
  # de un vistazo queda claro que esto no habilita esos días en general,
  # sólo bypasea unavailable_weekday? para esas fechas puntuales. El corte
  # horario normal (no se pide para el mismo día) sigue aplicando igual que
  # para cualquier otra fecha vía cutoff_passed?, así que a partir de que
  # efectivamente sea esa fecha deja de poder pedirse, igual que cualquier
  # otro día ya vencido.
  #   - jueves 17/09/2026: evento especial.
  #   - martes 22/09/2026: habilitado a pedido puntual del negocio.
  EXCEPTIONAL_AVAILABLE_DATES = [Date.new(2026, 9, 17), Date.new(2026, 9, 22)].freeze

  # Corte recurrente para la entrega del sábado: se acepta pedido hasta el
  # viernes anterior a esta hora (en vez de hasta la medianoche del propio
  # sábado, como el resto de los días habilitados). Aplica todas las semanas,
  # no es una excepción puntual de una fecha concreta.
  SATURDAY_CUTOFF_HOUR = 14

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
    return false if EXCEPTIONAL_AVAILABLE_DATES.include?(date)

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
    now >= cutoff_time
  end

  def cutoff_time
    if date.saturday?
      (date - 1).in_time_zone.change(hour: SATURDAY_CUTOFF_HOUR, min: 0, sec: 0)
    else
      date.in_time_zone.beginning_of_day
    end
  end
end
