# Día y franja horaria de una modalidad minorista (retiro por zona Plaza del Agua o envío a
# domicilio). Una fila por modalidad y día de la semana (wday: 0 = domingo … 6 = sábado). Las
# horas se guardan en minutos desde las 00:00, hora de Argentina. La franja es orientativa: no
# es un turno exacto.
class RetailServiceWindow < ApplicationRecord
  SERVICES = %w[pickup delivery].freeze
  DAY_NAMES = %w[Domingo Lunes Martes Miércoles Jueves Viernes Sábado].freeze
  # Orden de lectura en pantalla: lunes primero.
  WEEK_ORDER = [1, 2, 3, 4, 5, 6, 0].freeze

  validates :service, inclusion: { in: SERVICES }
  validates :wday, inclusion: { in: 0..6 }, uniqueness: { scope: :service }
  validates :opens_minute, :closes_minute, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 1440 }, allow_nil: true
  validate :hours_when_enabled

  scope :for_service, ->(service) { where(service: service.to_s) }

  def self.format_minute(minute)
    return nil if minute.nil?

    format("%d:%02d", minute / 60, minute % 60)
  end

  # "14:00" / "8:30" -> minutos; nil si no es una hora válida.
  def self.parse_minute(text)
    match = text.to_s.strip.match(/\A(\d{1,2}):(\d{2})\z/)
    return nil unless match

    hours = match[1].to_i
    minutes = match[2].to_i
    return nil if minutes > 59 || hours > 24 || (hours == 24 && minutes.positive?)

    hours * 60 + minutes
  end

  def day_name
    DAY_NAMES[wday]
  end

  def opens_at
    self.class.format_minute(opens_minute)
  end

  def closes_at
    self.class.format_minute(closes_minute)
  end

  # "14:00 a 17:00 hs"
  def label
    return nil unless enabled?

    "#{opens_at} a #{closes_at} hs"
  end

  private

  def hours_when_enabled
    return unless enabled?

    if opens_minute.nil? || closes_minute.nil?
      errors.add(:base, "#{day_name}: completá el horario de inicio y de fin.")
    elsif opens_minute >= closes_minute
      errors.add(:base, "#{day_name}: el horario de fin tiene que ser posterior al de inicio.")
    end
  end
end
