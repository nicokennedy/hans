module Admin::OrdersHelper
  # Atributos data de un <option> de producto para filtrar por cliente en el formulario del
  # pedido (ver order_items_controller.js). Es solo ayuda visual: el servidor valida igual.
  def product_visibility_data(product)
    {
      "data-name": product.name,
      "data-visibility": product.selected_customers? ? "selected" : "all",
      "data-customer-ids": product.selected_customers? ? product.product_customer_accesses.map(&:customer_id).join(",") : ""
    }
  end

  def product_option_choices(products)
    products.map { |p| [ p.name, p.id, { "data-price-amount": p.price_amount }.merge(product_visibility_data(p)) ] }
  end

  def order_item_product_options(item, active_products)
    products = active_products.to_a
    products << item.product unless item.product.active?
    options_for_select(product_option_choices(products), item.product_id)
  end
end
