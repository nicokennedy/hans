# Sabor de un producto con contenido personalizable (Etapa 2 del rediseño 2026): "Almendra",
# "Maicena", "Cacao"... Pertenece al producto y vale para TODAS sus variantes (cajas x 8, x 12, x 24).
#
# - active: disponibilidad manual desde el administrador. Un sabor deshabilitado no se ofrece en la
#   tienda; si ya estaba en un carrito, el cliente tiene que corregir la caja antes de finalizar.
# - position: orden en que se muestran.
# - No descuenta stock (decisión de la Etapa 2: el stock sigue por variante).
# - Los pedidos guardan una copia del nombre (RetailOrderItem#composition): renombrar o deshabilitar
#   un sabor no cambia pedidos ya hechos. Un sabor que ya se usó en pedidos no se borra: se deshabilita.
class RetailProductFlavor < ApplicationRecord
  belongs_to :retail_product, inverse_of: :flavors

  before_validation { self.name = name.to_s.squish.presence }

  validates :name, presence: true, length: { maximum: 60 }
  validates :position, numericality: { only_integer: true }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }

  # ¿Algún pedido lo tiene en su composición? (entonces no se borra, se deshabilita).
  def used_in_orders?
    return false unless persisted?

    RetailOrderItem.where("retail_order_items.composition -> 'flavors' @> ?", [{ id: id }].to_json).exists?
  end
end
