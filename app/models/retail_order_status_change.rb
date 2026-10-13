# Registro de cada cambio de estado operativo de un pedido minorista (quién, cuándo, de-a).
class RetailOrderStatusChange < ApplicationRecord
  belongs_to :retail_order
  belongs_to :user, optional: true

  validates :to_status, inclusion: { in: RetailOrder.statuses.keys }
end
