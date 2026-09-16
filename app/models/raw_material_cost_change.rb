# Historial append-only de RawMaterial. Se llama "CostChange" y no
# "PriceChange" a propósito: no solo el precio de compra puede alterar el
# costo normalizado — la cantidad comprada, la unidad de compra o la unidad
# base también pueden hacerlo (ej. "antes 1 kg a $10.000, ahora 500 g a
# $6.000" cambia el costo por kg sin que el precio "suba" en términos
# absolutos). Un registro acá siempre representa un cambio real en el costo
# efectivo, nunca una edición nominal sin impacto.
class RawMaterialCostChange < ApplicationRecord
  belongs_to :raw_material
  belongs_to :changed_by_user, class_name: "User", optional: true

  validates :previous_purchase_price_cents, :new_purchase_price_cents,
    :previous_unit_cost_cents, :new_unit_cost_cents,
    presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :previous_purchase_quantity, :new_purchase_quantity,
    presence: true, numericality: { greater_than: 0 }
  validates :previous_purchase_unit, :new_purchase_unit,
    presence: true, inclusion: { in: RawMaterial::PURCHASE_UNITS }
  validates :previous_base_unit, :new_base_unit,
    presence: true, inclusion: { in: RawMaterial::CANONICAL_BASE_UNITS }

  # Solo lectura una vez creado: nunca se edita ni se borra desde el admin.
  # No hay ninguna acción de controller que lo permita, y esto lo blinda
  # también a nivel modelo — cualquier intento de update (por más que en el
  # futuro alguien agregue una ruta por error) falla solo.
  def readonly?
    persisted?
  end
end
