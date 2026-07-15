class DeliveryDateValidator
  UNAVAILABLE_WEEKDAYS = [0].freeze

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
    return "No tenemos entregas ese día" if unavailable_weekday?
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

  def cutoff_passed?
    cutoff_time = date.in_time_zone.beginning_of_day
    now >= cutoff_time
  end
end
