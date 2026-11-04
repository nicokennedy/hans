# Carrito de la tienda (en la sesión, ver Retail::StoreCart). Solo recibe ids de producto y
# cantidades: los precios se consultan siempre en el servidor.
class Store::CartsController < Store::BaseController
  before_action -> { throttle!(:cart) }, only: [:add, :update_item, :remove_item]

  def show
    @lines = store_cart.lines
    @dropped = store_cart.dropped
  end

  def add
    message = store_cart.add(params[:product_id], params[:quantity].presence || 1)
    if message && !store_cart.contents.key?(params[:product_id].to_s)
      redirect_back fallback_location: store_root_path, alert: message, status: :see_other
    else
      redirect_to store_cart_path, status: :see_other, notice: message || "Agregamos el producto a tu carrito.",
        flash: { store_added: params[:product_id].to_s }
    end
  end

  def update_item
    message = store_cart.update(params[:product_id], params[:quantity])
    redirect_to store_cart_path, status: :see_other, alert: message
  end

  def remove_item
    store_cart.remove(params[:product_id])
    redirect_to store_cart_path, status: :see_other, notice: "Sacamos el producto del carrito."
  end
end
