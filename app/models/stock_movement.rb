# Ledger append-only de StockItem. Nunca se edita ni se borra — cualquier
# corrección futura es un movimiento NUEVO (ver StockItem#apply_movement!/#count!),
# nunca una edición de uno existente. quantity es siempre con signo
# (positivo = entra, negativo = sale); resulting_quantity es una foto del
# stock resultante justo después de este movimiento, para poder pintar el
# historial sin tener que recorrer/sumar todo el ledger cada vez.
class StockMovement < ApplicationRecord
  belongs_to :stock_item
  belongs_to :order, optional: true
  belongs_to :user, optional: true

  # "dispatch" cubre tanto la salida original como cualquier corrección
  # posterior por delta (ver Stock::DispatchReconciler) — el signo de
  # quantity ya distingue "salió más" de "volvió al stock", no hace falta
  # un tipo separado de "reversión".
  enum :movement_type, {
    production: "production",
    dispatch: "dispatch",
    adjustment: "adjustment"
  }

  validates :movement_type, presence: true
  validates :quantity, presence: true, numericality: { other_than: 0 }
  validates :resulting_quantity, presence: true

  # Solo lectura una vez creado — mismo criterio que RawMaterialCostChange.
  def readonly?
    persisted?
  end
end
