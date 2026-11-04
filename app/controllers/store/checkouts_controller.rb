# Checkout de la tienda: datos del cliente, entrega, forma de pago y "Enviar pedido por WhatsApp".
#
# Al enviar, el servidor valida todo y crea el pedido con Retail::PlaceStoreOrder (precios del
# catálogo, envío de la zona, fecha según la Etapa 3). El pedido queda "Pendiente de confirmación"
# en Pedidos Minoristas ANTES de abrir WhatsApp: guardar nunca depende de que el mensaje se envíe.
#
# Duplicados: cada checkout lleva un token propio (en la sesión y en el formulario). Doble toque,
# recarga o volver atrás devuelven el mismo pedido (índice único de request_token).
# Abuso: campo trampa invisible (honeypot) y límite de envíos por IP (Retail::StoreThrottle).
# Vista previa (tienda cerrada, administrador): valida y arma el pedido y el mensaje en memoria, sin
# escribir nada en la base (Retail::PlaceStoreOrder.preview).
class Store::CheckoutsController < Store::BaseController
  TOKEN_KEY = :retail_store_checkout_token
  PLACED_KEY = :retail_store_placed_orders
  HONEYPOT = :website

  def show
    return redirect_to(store_cart_path, status: :see_other) if store_cart.empty?

    @form = { delivery_kind: "pickup" }
    prepare_form
  end

  def create
    return unless throttle!(:checkout)

    form_token = params[:checkout_token].to_s
    # El mismo formulario enviado otra vez después de registrar el pedido (doble toque, recarga,
    # volver atrás desde WhatsApp): el mismo pedido, nunca otro.
    return if redirect_to_placed_order(form_token)
    return redirect_to(store_cart_path, status: :see_other, alert: "Tu carrito está vacío.") if store_cart.empty?

    @form = form_params
    if params[HONEYPOT].present?
      Rails.logger.info("[tienda] envío descartado por el campo trampa")
      return redirect_to(store_cart_path, status: :see_other, alert: "No pudimos procesar el pedido. Probá de nuevo.")
    end

    if form_token.blank? || form_token != session[TOKEN_KEY]
      @errors = ["El formulario se venció. Revisá los datos y tocá de nuevo «Enviar pedido por WhatsApp»."]
      return render_form
    end

    return preview_order if store_preview?
    return unless throttle!(:order)

    result = Retail::PlaceStoreOrder.call(attributes: @form, cart: store_cart.contents, request_token: "store-#{form_token}")
    unless result.ok?
      @errors = result.errors
      return render_form
    end

    order = result.record
    remember_placed(order)
    store_cart.clear
    session.delete(TOKEN_KEY)
    flash[:store_open_whatsapp] = true unless result.duplicate?
    redirect_to store_order_path(order.public_token), status: :see_other
  end

  private

  def form_params
    params.permit(*Retail::PlaceStoreOrder::CUSTOMER_FIELDS - [:delivery_date], :pickup_date, :delivery_date).to_h.symbolize_keys.tap do |form|
      # Cada modalidad tiene su propia lista de fechas en el formulario.
      form[:delivery_date] = form[:delivery_kind] == "delivery" ? form[:delivery_date] : form.delete(:pickup_date)
      form.delete(:pickup_date)
    end
  end

  def prepare_form
    session[TOKEN_KEY] ||= SecureRandom.alphanumeric(32)
    @checkout_token = session[TOKEN_KEY]
    @lines = store_cart.lines
    @dropped = store_cart.dropped
    @subtotal_cents = store_cart.subtotal_cents
    @options = RetailFulfillment::Options.call
    @zones = RetailDeliveryZone.active.ordered.to_a
  end

  def render_form
    prepare_form
    render :show, status: :unprocessable_entity
  end

  # El mismo formulario enviado de nuevo después de registrar el pedido (recarga, doble toque que
  # llegó tarde, volver atrás): si ese pedido es de esta sesión, se muestra ese mismo pedido.
  def redirect_to_placed_order(form_token)
    return false if form_token.blank?

    order = RetailOrder.find_by(request_token: "store-#{form_token}")
    return false unless order && Array(session[PLACED_KEY]).include?(order.public_token)

    redirect_to store_order_path(order.public_token), status: :see_other
    true
  end

  def remember_placed(order)
    session[PLACED_KEY] = (Array(session[PLACED_KEY]) - [order.public_token]).push(order.public_token).last(5)
  end

  # Tienda cerrada + administrador: las mismas validaciones, precios, envío y mensaje, con el pedido
  # armado en memoria: no se escribe nada en la base.
  def preview_order
    result = Retail::PlaceStoreOrder.preview(attributes: @form, cart: store_cart.contents)
    unless result.ok?
      @errors = result.errors
      return render_form
    end

    order = result.record
    message = Retail::StoreWhatsappMessage.new(order, number: @store_setting.whatsapp_number, preview: true)
    @preview = { order: order, items: order.retail_order_items.to_a, text: message.text, url: message.url }
    render :preview
  end
end
