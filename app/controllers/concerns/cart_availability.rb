# Visibilidad de productos por cliente en el carrito del cliente mayorista. El carrito vive en
# la sesión, así que puede contener productos que dejaron de estar habilitados para el cliente
# (o ids manipulados): nunca se convierten en un pedido, ni parcial ni total (ver también
# Order#items_available_to_customer_on_create, que valida lo mismo en el modelo).
module CartAvailability
  extend ActiveSupport::Concern

  private

  # Nombres de los productos del carrito que el cliente no puede pedir.
  def unavailable_cart_product_names(cart_items)
    customer = current_user.customer
    cart_items.reject { |item| item[:product].available_to?(customer) }.map { |item| item[:product].name }
  end

  # Quita del carrito (sesión) los productos no habilitados; devuelve sus nombres.
  def purge_unavailable_cart_products!(cart_items)
    customer = current_user.customer
    removed = cart_items.reject { |item| item[:product].available_to?(customer) }

    removed.each { |item| current_cart.delete(item[:product].id.to_s) }
    removed.map { |item| item[:product].name }
  end

  def unavailable_cart_message(names)
    "Este producto no está disponible para tu cliente: #{names.to_sentence}."
  end
end
