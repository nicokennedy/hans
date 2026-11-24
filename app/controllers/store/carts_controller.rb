# Carrito de la tienda (en la sesión, ver Retail::StoreCart). Solo recibe ids de variante (tamaño o
# presentación) y cantidades: los precios se consultan siempre en el servidor.
#
# Compatibilidad: también acepta product_id para productos de una sola variante (las tarjetas del
# catálogo de productos simples y enlaces anteriores). Un producto con varios tamaños exige elegirlo.
class Store::CartsController < Store::BaseController
  before_action -> { throttle!(:cart) }, only: [:add, :update_item, :remove_item, :replace_item]

  def show
    @lines = store_cart.lines
    @dropped = store_cart.dropped
    @problems = store_cart.problems?
  end

  def add
    variant_id = requested_variant_id
    return redirect_back(fallback_location: store_root_path, alert: @variant_error, status: :see_other) unless variant_id

    before = store_cart.contents
    message = store_cart.add(variant_id, params[:quantity].presence || 1, flavors: params[:flavors])
    added = store_cart.contents.find { |key, quantity| before[key] != quantity }&.first
    if message && !added
      redirect_back fallback_location: store_root_path, alert: message, status: :see_other
    else
      redirect_to store_cart_path, status: :see_other, notice: message || "Agregamos el producto a tu carrito.",
        flash: { store_added: added }
    end
  end

  # Cajas con contenido personalizable: guarda los sabores nuevos de una caja del carrito (misma
  # cantidad de cajas; si ya había una caja igual, se suman).
  def replace_item
    message = store_cart.replace(params[:line], params[:variant_id], flavors: params[:flavors])
    if message
      redirect_back fallback_location: store_cart_path, alert: message, status: :see_other
    else
      redirect_to store_cart_path, status: :see_other, notice: "Actualizamos los sabores de la caja."
    end
  end

  def update_item
    message = store_cart.update(line_key, params[:quantity])
    redirect_to store_cart_path, status: :see_other, alert: message
  end

  def remove_item
    store_cart.remove(line_key)
    redirect_to store_cart_path, status: :see_other, notice: "Sacamos el producto del carrito."
  end

  private

  # Línea del carrito: la clave (variante o variante + sabores) o, en formularios anteriores, el id
  # de variante o de producto.
  def line_key
    return params[:line].to_s if Retail::BoxComposition.valid_key?(params[:line])

    requested_variant_id || params[:variant_id]
  end

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
