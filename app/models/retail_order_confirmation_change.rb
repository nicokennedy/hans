# Registro de cada cambio de confirmación de un pedido minorista (quién, cuándo, de-a, motivo).
class RetailOrderConfirmationChange < ApplicationRecord
  belongs_to :retail_order
  belongs_to :user, optional: true

  validates :from_status, :to_status, inclusion: { in: RetailOrder.confirmation_statuses.keys }
end
