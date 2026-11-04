# Reglas generales de entrega de la tienda minorista (una sola fila): anticipación mínima en días
# calendario e indicaciones del punto de retiro. Independiente del reparto mayorista
# (DeliverySetting). Ver RetailFulfillment::Calendar.
class RetailFulfillmentSetting < ApplicationRecord
  MAX_LEAD_DAYS = 30

  before_validation { self.pickup_point_details = pickup_point_details.to_s.strip.presence }

  validates :min_lead_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_LEAD_DAYS }
  validates :pickup_point_details, length: { maximum: 1000 }, allow_nil: true

  # La fila de configuración; si no existe (base nueva o tests) instala la configuración inicial.
  def self.current
    first || RetailFulfillment::Defaults.install!
  end
end
