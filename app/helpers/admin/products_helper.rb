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
      "$#{number_with_delimiter(product.cost_amount)}"
    else
      product.public_send(field)
    end
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
end
