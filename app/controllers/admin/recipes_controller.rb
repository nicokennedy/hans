# Vista de solo lectura sobre los Product existentes y su ProductRecipe
# (si tienen una) — NO es un modelo ni concepto nuevo, es el mismo
# Product/ProductRecipe de siempre, solo que hasta ahora la receta de un
# producto estaba escondida dentro de la pantalla de edición de ese
# producto. Acá se listan todos juntos para que sea fácil ver de un
# vistazo qué productos tienen costo por receta, cuáles están en borrador,
# y cuáles ni siquiera empezaron.
class Admin::RecipesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    @products = Product.includes(product_recipe: { recipe_components: :component }).ordered
  end
end
