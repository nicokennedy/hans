# Ficha de stock de UN Product o UNA Preparation — polimórfico a propósito,
# porque ambos necesitan el mismo comportamiento (cantidad física, mínimo,
# ledger de movimientos) sin duplicar columnas/lógica en dos tablas. La
# EXISTENCIA de esta fila con active: true ES el "control_stock" del
# pedido original — no hay una columna separada en Product/Preparation.
# active: false (default) es la forma de desactivar sin perder historial,
# mismo criterio "desactivar, no borrar" que ya usan RawMaterial/Preparation.
#
# La unidad NO se guarda acá: se deriva de stockable (Preparation#yield_unit,
# o "un" fijo para Product) para no tener una segunda fuente de verdad que
# se pueda desincronizar de la que ya define la receta.
class StockItem < ApplicationRecord
  belongs_to :stockable, polymorphic: true
  has_many :stock_movements, dependent: :restrict_with_error

  validates :minimum_quantity, presence: true, numericality: { greater_than_or_equal_to: 0 }
  validates :quantity, presence: true, numericality: {}
  # Desde qué fecha de ENTREGA participa del control de stock: los pedidos con
  # delivery_date anterior no comprometen ni descuentan nada (ver
  # Stock::Availability y Stock::DispatchReconciler). Dato explícito, no se
  # deriva de created_at; para ítems nuevos arranca hoy.
  attribute :stock_tracking_started_on, :date, default: -> { Date.current }
  validates :stock_tracking_started_on, presence: true
  # Cantidad que rinde una tanda completa. Opcional; solo recomienda cuántas
  # tandas preparar (ver Stock::Availability) — nunca limita lo que se registra.
  validates :production_batch_size, numericality: { greater_than: 0 }, allow_nil: true
  validates :stockable_id, uniqueness: { scope: :stockable_type }

  scope :active, -> { where(active: true) }

  def unit
    stockable.is_a?(Preparation) ? stockable.yield_unit : "un"
  end

  def name
    stockable.name
  end

  # Único camino legítimo para aplicar un movimiento de cantidad CONOCIDA
  # (producción, o la corrección delta de Stock::DispatchReconciler).
  # with_lock abre una transacción y toma un lock de fila sobre este
  # StockItem antes de leer/escribir quantity — así dos movimientos
  # concurrentes sobre el mismo ítem (ej. dashboard + rake task, o dos
  # pedidos tocando el mismo Brownie a la vez) se serializan en vez de
  # pisarse.
  def apply_movement!(movement_type:, quantity:, order: nil, user: nil, note: nil)
    signed_quantity = quantity.to_d
    return nil if signed_quantity.zero?

    with_lock do
      new_quantity = self.quantity.to_d + signed_quantity
      movement = stock_movements.create!(
        movement_type: movement_type,
        quantity: signed_quantity,
        resulting_quantity: new_quantity,
        order: order,
        user: user,
        note: note
      )
      update!(quantity: new_quantity)
      movement
    end
  end

  # Conteo físico: a diferencia de apply_movement!, acá el dato de entrada
  # es un valor ABSOLUTO ("conté 13"), no un delta — el delta se calcula
  # adentro del lock a propósito, contra el valor más actual posible, para
  # no perder una corrección si algo más movió el stock justo antes.
  def count!(counted_quantity:, user:, note: nil)
    with_lock do
      delta = counted_quantity.to_d - quantity.to_d
      next nil if delta.zero?

      movement = stock_movements.create!(
        movement_type: :adjustment,
        quantity: delta,
        resulting_quantity: counted_quantity.to_d,
        user: user,
        note: note
      )
      update!(quantity: counted_quantity.to_d)
      movement
    end
  end
end
