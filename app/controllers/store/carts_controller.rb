# Carrito de la tienda (en la sesión, ver Retail::StoreCart). Solo recibe ids de variante (tamaño o
# presentación) y cantidades: los precios se consultan siempre en el servidor.
#
# Compatibilidad: también acepta product_id para productos de una sola variante (las tarjetas del
# catálogo de productos simples y enlaces anteriores). Un producto con varios tamaños exige elegirlo.
class Store::CartsController < Store::BaseController
  before_action -> { throttle!(:cart) }, only: [:add, :update_item, :remove_item]

  def show
    @lines = store_cart.lines
    @dropped = store_cart.dropped
  end

  def add
    variant_id = requested_variant_id
    return redirect_back(fallback_location: store_root_path, alert: @variant_error, status: :see_other) unless variant_id

    message = store_cart.add(variant_id, params[:quantity].presence || 1)
    if message && !store_cart.contents.key?(variant_id.to_s)
      redirect_back fallback_location: store_root_path, alert: message, status: :see_other
    else
      redirect_to store_cart_path, status: :see_other, notice: message || "Agregamos el producto a tu carrito.",
        flash: { store_added: variant_id.to_s }
    end
  end

  def update_item
    message = store_cart.update(requested_variant_id || params[:variant_id], params[:quantity])
    redirect_to store_cart_path, status: :see_other, alert: message
  end

  def remove_item
    store_cart.remove(requested_variant_id || params[:variant_id])
    redirect_to store_cart_path, status: :see_other, notice: "Sacamos el producto del carrito."
  end

  private

  def requested_variant_id
    return params[:variant_id].to_s if params[:variant_id].to_s.match?(/\A\d{1,18}\z/)

    @variant_error = "Ese producto no está disponible."
    return nil unless params[:product_id].to_s.match?(/\A\d{1,18}\z/)

    product = RetailProduct.for_store.includes(:variants).find_by(id: params[:product_id].to_i)
    return nil unless product

    active = product.variants.select(&:active?)
    if active.size > 1
      @variant_error = active.all? { |v| v.name.to_s.match?(/\d\s*cm\b/i) } ? "Elegí el tamaño de “#{product.name}”." : "Elegí la presentación de “#{product.name}”."
      return nil
    end
    active.first&.id&.to_s
  end
end
