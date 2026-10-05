# Dice de qué objeto físico de stock descuenta un Product cuando se vende,
# SIN pasar por su receta. Es una relación operativa aparte del costeo: la
# receta (RecipeComponent) sigue describiendo ingredientes y costo; esto solo
# describe qué se cuenta en el freezer (ej. "1 unidad de Tapas Alfajor
# Almendra" por cada Alfajor Almendras vendido).
#
# La preparación tiene que ser stock_only: así nunca puede estar también
# en una receta, y por lo tanto este vínculo no puede duplicar un costo.
class ProductStockSource < ApplicationRecord
  belongs_to :product
  belongs_to :preparation

  validates :quantity, presence: true, numericality: { greater_than: 0 }
  validates :preparation_id, uniqueness: { scope: :product_id }
  validate :preparation_must_be_stock_only

  private

  def preparation_must_be_stock_only
    return if preparation.blank? || preparation.stock_only?

    errors.add(:preparation, "tiene que ser un objeto de stock (\"solo stock\"), no una preparación de receta")
  end
end
