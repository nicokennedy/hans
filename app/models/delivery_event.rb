# Historial de un recorrido (Repartos): quién hizo qué y cuándo, con los datos de antes y
# después. Solo inserción: no se edita ni se borra.
class DeliveryEvent < ApplicationRecord
  LABELS = {
    "route_created" => "Armó el recorrido",
    "stop_added" => "Agregó una parada",
    "stops_grouped" => "Unificó pedidos para la entrega",
    "stops_ungrouped" => "Desagrupó los pedidos",
    "stop_moved" => "Cambió el orden",
    "stop_removed" => "Quitó una parada",
    "stop_restored" => "Volvió a agregar una parada",
    "stop_updated" => "Editó una parada",
    "driver_assigned" => "Asignó el repartidor",
    "stop_transferred_out" => "Pasó un pedido a otro repartidor",
    "stop_transferred_in" => "Recibió un pedido de otro repartidor",
    "stop_delivered" => "Registró una entrega",
    "stop_not_delivered" => "Registró una entrega no realizada",
    "stop_done" => "Registró una parada hecha",
    "collection_recorded" => "Registró un cobro",
    "collection_corrected" => "Corrigió un cobro",
    "collection_voided" => "Anuló un cobro",
    "payment_reported" => "Informó que no le pagaron",
    "photo_added" => "Subió la foto del remito",
    "receipt_exception" => "Registró que el cliente no firmó",
    "income_recorded" => "Registró otro ingreso",
    "income_corrected" => "Corrigió un ingreso",
    "income_voided" => "Anuló un ingreso",
    "expense_recorded" => "Registró un gasto",
    "expense_corrected" => "Corrigió un gasto",
    "expense_voided" => "Anuló un gasto",
    "settlement_submitted" => "Envió la rendición",
    "settlement_confirmed" => "Confirmó el cierre"
  }.freeze

  belongs_to :delivery_route, inverse_of: :events
  belongs_to :delivery_stop, optional: true
  belongs_to :user

  validates :event_type, inclusion: { in: LABELS.keys }

  before_update { raise ActiveRecord::ReadOnlyRecord, "El historial de repartos no se modifica." }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "El historial de repartos no se borra." }

  def label
    LABELS.fetch(event_type, event_type)
  end

  def summary
    data["summary"].presence || label
  end
end
