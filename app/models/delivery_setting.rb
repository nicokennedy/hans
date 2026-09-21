class DeliverySetting < ApplicationRecord
  validates :cutoff_hour, presence: true

  def self.current
    first_or_create!(
      cutoff_hour: 0,
      unavailable_weekdays: DeliveryDateValidator.unavailable_weekdays
    )
  end

  # exceptional_available_dates se persiste como jsonb (array de strings
  # ISO8601, igual que unavailable_weekdays ya persiste sus wdays como
  # jsonb) — nunca como constante Ruby. Es la fuente única de verdad que
  # consultan DeliveryDateValidator, el date picker del cliente y esta
  # pantalla de Admin; no hay una segunda copia hardcodeada en ningún lado.
  def exceptional_dates
    Array(exceptional_available_dates).map { |d| Date.parse(d.to_s) }
  end

  def exceptional_date?(date)
    exceptional_dates.include?(date.to_date)
  end

  # Idempotente a propósito: agregar una fecha ya habilitada no debe fallar
  # ni duplicarla, simplemente no hace nada (ver Admin::ExceptionalDeliveryDatesController#create).
  def add_exceptional_date!(date)
    date = date.to_date
    return if exceptional_date?(date)

    update!(exceptional_available_dates: (exceptional_dates + [date]).sort.map(&:iso8601))
  end

  def remove_exceptional_date!(date)
    date = date.to_date
    update!(exceptional_available_dates: exceptional_dates.reject { |d| d == date }.map(&:iso8601))
  end
end
