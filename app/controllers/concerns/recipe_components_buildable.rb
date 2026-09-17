# Permite que la pantalla de alta de una Preparation o de una ProductRecipe
# arme sus RecipeComponent en el mismo submit que crea al dueño — en vez de
# obligar a guardar primero y recién ahí poder cargar componentes. No
# reemplaza nada de la arquitectura de costeo: sigue siendo el mismo
# RecipeComponent polimórfico de siempre, simplemente se construyen varias
# líneas en memoria antes de guardar (mismo patrón ya usado en HANS para
# Order + order_items, ver Admin::OrdersController).
module RecipeComponentsBuildable
  extend ActiveSupport::Concern

  private

  # `rows` es el array plano que llega en params[:recipe_components] (uno
  # por fila del formulario, formato "recipe_components[][component_ref]").
  # Filas sin componente elegido se descartan en silencio — son las filas
  # en blanco que se muestran de entrada para invitar a cargar, no un error.
  def build_recipe_components(owner, rows)
    Array(rows).each do |row|
      next if row[:component_ref].blank?

      owner.recipe_components.build(
        component: RecipeComponent.resolve_component(row[:component_ref]),
        quantity: row[:quantity],
        unit: row[:unit]
      )
    end
  end

  # Deliberadamente distinto de los `load_component_form_data` de cada
  # controller de edición: acá no hace falta excluir self ni filtrar
  # ciclos (un registro todavía no creado no puede depender de nada, ni
  # nada puede depender de él).
  def load_recipe_component_options
    @raw_material_options = RawMaterial.active.order(:name)
    @preparation_options = Preparation.active.order(:name)
  end
end
