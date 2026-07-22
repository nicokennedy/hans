module Admin::OrdersHelper
  def order_item_product_options(item, active_products)
    products = active_products.to_a
    products << item.product unless item.product.active?
    options_from_collection_for_select(products, :id, :name, item.product_id)
  end
end
