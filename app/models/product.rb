# app/models/product.rb
class Product < ApplicationRecord
  belongs_to :category

  # dependent: :destroy porque una ProductRecipe es dato propio del
  # producto (nadie más la referencia — ver RecipeComponent::ALLOWED_COMPONENT_TYPES,
  # que nunca incluye "ProductRecipe"), mismo criterio que Order/order_items.
  has_one :product_recipe, dependent: :destroy

  # "manual": cost_cents se carga/edita a mano (default — todo producto nace
  # así). "recipe": cost_cents lo gobierna la ProductRecipe activa (Fase
  # 4/5) — ver Costing::ActivateProductRecipe/SyncProductCost.
  enum :cost_source, { manual: "manual", recipe: "recipe" }, default: "manual"

  validates :name, :price_cents, presence: true
  validates :cost_source, presence: true
  validates :price_cents, :cost_cents,
    numericality: { greater_than_or_equal_to: 0 },
    allow_nil: true
  validate :cost_cents_not_manually_edited_while_recipe_sourced

  scope :active, -> { where(active: true) }
  scope :ordered, -> {
    joins(:category)
      .order("categories.position ASC, products.position ASC, products.name ASC")
  }

  def price
    price_cents.to_i / 100.0
  end

  def price_amount
    price_cents.to_i / 100
  end

  def price_amount=(value)
    self.price_cents = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  def cost_amount
    cost_cents.to_i / 100
  end

  def cost_amount=(value)
    self.cost_cents = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  # --- Escritura interna privilegiada del motor de costeo ------------------
  # update_columns salta validaciones Y callbacks a propósito: es la única
  # vía por la que cost_cents puede cambiar mientras cost_source == recipe.
  # Un admin editando por un form/inline/importer pasa siempre por
  # save/update normal, que SÍ corre cost_cents_not_manually_edited_while_recipe_sourced
  # y lo rechaza. No hay ningún flag global ni contexto oculto: el único
  # camino de escritura legítimo son estos tres métodos, todos con nombre
  # explícito de lo que hacen.

  def activate_recipe_cost!(cost_cents)
    update_columns(cost_source: "recipe", cost_cents: cost_cents, updated_at: Time.current)
  end

  def sync_recipe_cost!(cost_cents)
    update_columns(cost_cents: cost_cents, updated_at: Time.current)
  end

  # cost_cents queda tal cual estaba a propósito — es el "punto de partida"
  # manual que pidió conservar el negocio al volver de recipe a manual.
  def deactivate_recipe_cost!
    update_columns(cost_source: "manual", updated_at: Time.current)
  end

  private

  # Solo bloquea un UPDATE normal sobre un producto recipe-sourced ya
  # existente (el camino real de un form/inline/importer editando a mano).
  # No bloquea la creación: nacer con cost_source: "recipe" y un cost_cents
  # inicial es un caso legítimo (consola, seeds, datos de otro sistema) que
  # no pasa por Costing::ActivateProductRecipe.
  def cost_cents_not_manually_edited_while_recipe_sourced
    return if new_record?
    return unless recipe? && cost_cents_changed?

    errors.add(:cost_cents, "está gobernado por la receta activa — no se puede editar manualmente")
  end
end