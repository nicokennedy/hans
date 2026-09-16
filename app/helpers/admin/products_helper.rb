module Admin::ProductsHelper
  def inline_field_display(product, field)
    case field
    when "category_id"
      product.category&.name
    when "internal_category"
      product.internal_category.presence || "-"
    when "price_amount"
      "$#{number_with_delimiter(product.price_amount)}"
    when "cost_amount"
      if product.recipe?
        "$#{number_with_delimiter(product.cost_amount)} (calculado por receta)"
      else
        "$#{number_with_delimiter(product.cost_amount)}"
      end
    else
      product.public_send(field)
    end
  end

  def cost_field_editable?(product, field)
    field != "cost_amount" || !product.recipe?
  end

  def inline_field_input(form, field)
    case field
    when "category_id"
      form.collection_select :category_id, Category.ordered, :id, :name, {},
        class: "form-select form-select-sm", style: "width: auto;"
    when "price_amount", "cost_amount"
      form.number_field field, min: 0, class: "form-control form-control-sm", style: "width: 90px;"
    else
      form.text_field field, class: "form-control form-control-sm", style: "width: 140px;"
    end
  end

  # Igual criterio que Admin::PreparationsHelper#preparation_cost_display:
  # nunca debería fallar por un camino validado, pero si una ProductRecipe
  # quedara con datos corruptos no hay que tirar abajo la pantalla de
  # edición del producto por eso.
  def product_recipe_cost_display(product_recipe)
    [ format_money(product_recipe.total_cost_cents), format_money(product_recipe.unit_cost_cents) ]
  rescue Costing::PreparationCalculator::CircularDependencyError,
         Measurement::UnitConverter::UnknownUnitError,
         Measurement::UnitConverter::IncompatibleUnitsError
    [ "—", "—" ]
  end
end
