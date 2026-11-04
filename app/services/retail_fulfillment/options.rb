module RetailFulfillment
  # Lo que necesita el checkout de la tienda pública para armar el paso de entrega, en un Hash
  # listo para JSON: modalidades con su costo, días habituales y franjas, fechas habilitadas
  # (ya con anticipación y excepciones aplicadas) y zonas activas con su precio. La validación
  # final la hace siempre RetailFulfillment::Quote en el servidor.
  module Options
    module_function

    def call(now: Time.current)
      calendar = Calendar.new(now: now)
      zones = RetailDeliveryZone.active.ordered.to_a
      windows = RetailServiceWindow.where(enabled: true).to_a.group_by(&:service)

      {
        today: calendar.today.iso8601,
        min_lead_days: calendar.min_lead_days,
        earliest_date: calendar.earliest_date.iso8601,
        last_date: calendar.last_date.iso8601,
        services: RetailServiceWindow::SERVICES.map do |service|
          {
            key: service,
            name: RetailFulfillment.service_name(service),
            window_name: RetailFulfillment::WINDOW_NAMES[service],
            cost: service == "pickup" ? "$0 — Gratis" : "Según la zona",
            details: service == "pickup" ? calendar.setting.pickup_point_details : nil,
            weekly: Array(windows[service]).sort_by { |w| RetailServiceWindow::WEEK_ORDER.index(w.wday) }
              .map { |w| { wday: w.wday, day: w.day_name, label: w.label } },
            dates: calendar.available_dates(service).map { |date| { date: date.iso8601, label: calendar.window_label(service, date) } }
          }
        end,
        zones: zones.map { |z| { id: z.id, name: z.name, coverage: z.coverage, price_cents: z.price_cents, price: "$#{Retail::Money.format_pesos(z.price_cents)}" } }
      }
    end
  end
end
