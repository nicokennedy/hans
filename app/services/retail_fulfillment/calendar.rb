module RetailFulfillment
  # Fechas habilitadas para retiro y envío.
  #
  # Primera fecha posible = fecha de HOY en Argentina + anticipación mínima en días calendario
  # (no horas: un pedido del lunes a las 23:30 puede entregarse el miércoles, igual que uno del
  # lunes a las 10:00). Desde ahí valen solo los días de la semana habilitados para esa modalidad
  # y que no tengan una fecha excepcional sin servicio (RetailServiceClosure), hasta HORIZON_DAYS.
  class Calendar
    attr_reader :today, :setting

    def initialize(now: Time.current, setting: nil)
      @today = RetailFulfillment.today(now)
      @setting = setting || RetailFulfillmentSetting.current
      @windows = RetailServiceWindow.all.index_by { |w| [w.service, w.wday] }
      @closures = RetailServiceClosure.where(date: today..last_date).to_a.group_by(&:date)
    end

    def min_lead_days
      setting.min_lead_days
    end

    def earliest_date
      today + min_lead_days
    end

    def last_date
      today + HORIZON_DAYS
    end

    def window(service, date)
      window = @windows[[service.to_s, date.wday]]
      window if window&.enabled?
    end

    def window_label(service, date)
      window(service, date)&.label
    end

    def closure(service, date)
      Array(@closures[date]).find { |c| c.service == "all" || c.service == service.to_s }
    end

    # nil si la fecha está habilitada; si no, el motivo para mostrarle al cliente.
    def unavailable_reason(service, date)
      service = service.to_s
      return "Elegí una modalidad de entrega válida." unless RetailServiceWindow::SERVICES.include?(service)
      return "Elegí una fecha de entrega." if date.nil?

      name = RetailFulfillment.service_name(service)
      if date < earliest_date
        first = first_available_date(service)
        message = "Los pedidos necesitan al menos #{min_lead_days} #{min_lead_days == 1 ? 'día' : 'días'} de anticipación"
        return first ? "#{message}: la primera fecha disponible es el #{RetailFulfillment.format_date(first)}." : "#{message}."
      end
      return "Por ahora se puede elegir una fecha hasta el #{last_date.strftime('%d/%m/%Y')}." if date > last_date
      return "Los #{RetailFulfillment.day_plural(date)} no hay #{name.downcase_first}." unless window(service, date)

      if (closed = closure(service, date))
        message = "El #{RetailFulfillment.format_date(date)} no hay #{name.downcase_first}"
        return closed.reason ? "#{message}: #{closed.reason}." : "#{message}."
      end

      nil
    end

    def available?(service, date)
      unavailable_reason(service, date).nil?
    end

    def available_dates(service)
      (earliest_date..last_date).select { |date| available?(service, date) }
    end

    def first_available_date(service)
      (earliest_date..last_date).find { |date| available?(service, date) }
    end
  end
end
