module RetailFulfillment
  # Configuración inicial de la Etapa 3 (la misma que carga la migración
  # 20261104190000_create_retail_fulfillment). Se instala sola en una base nueva o en los tests
  # cuando todavía no hay fila de configuración; después todo se cambia desde el administrador.
  module Defaults
    MIN_LEAD_DAYS = 2

    # [wday, opens, closes] en minutos desde las 00:00. Domingos sin servicio.
    WINDOWS = {
      "pickup" => { 1 => [840, 1020], 2 => [840, 1020], 3 => [840, 1020], 4 => [840, 1020], 5 => [840, 1020], 6 => [660, 780] },
      "delivery" => { 1 => [510, 780], 2 => [510, 780], 3 => [510, 780], 4 => [510, 780], 5 => [510, 780], 6 => [510, 780] }
    }.freeze

    ZONES = [
      { name: "Zona 1", coverage: "Costa, Independencia, Colón, Vértiz", price_cents: 500_000 },
      { name: "Zona 2", coverage: "Centro, zona Facultad", price_cents: 600_000 },
      { name: "Zona 3", coverage: "Constitución, barrios privados, Champagnat hasta Allio", price_cents: 700_000 }
    ].freeze

    module_function

    # Idempotente: si ya hay configuración no toca nada (tampoco recrea zonas borradas).
    def install!
      RetailFulfillmentSetting.transaction do
        existing = RetailFulfillmentSetting.lock.first
        return existing if existing

        RetailServiceWindow::SERVICES.each do |service|
          (0..6).each do |wday|
            hours = WINDOWS.fetch(service)[wday]
            RetailServiceWindow.find_or_create_by!(service: service, wday: wday) do |window|
              window.enabled = hours.present?
              window.opens_minute, window.closes_minute = hours
            end
          end
        end
        if RetailDeliveryZone.none?
          ZONES.each_with_index { |zone, index| RetailDeliveryZone.create!(zone.merge(position: index + 1, active: true)) }
        end
        RetailFulfillmentSetting.create!(min_lead_days: MIN_LEAD_DAYS)
      end
    end
  end
end
