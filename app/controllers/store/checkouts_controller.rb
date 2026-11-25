# Checkout de la tienda: datos del cliente, entrega, forma de pago y "Finalizar pedido por WhatsApp".
#
# Al enviar, el servidor valida todo y crea el pedido con Retail::PlaceStoreOrder (precios del
# catálogo, envío de la zona, fecha según la Etapa 3). El pedido queda "Pendiente de confirmación"
# en Pedidos Minoristas ANTES de abrir WhatsApp: guardar nunca depende de que el mensaje se envíe.
#
# Apertura de WhatsApp en un solo toque: el formulario se envía como navegación normal (sin Turbo ni
# fetch) y, registrado el pedido, la respuesta es una redirección 303 a wa.me con el mensaje armado
# desde el pedido guardado. Al ser la misma navegación que inició el toque del cliente, Safari (iPhone)
# y Chrome (Android) abren WhatsApp sin bloquearlo: no hay ventana emergente ni apertura posterior a
# una petición asíncrona. Si el registro falla, se vuelve a mostrar el formulario y WhatsApp no se abre.
# Abrir WhatsApp no confirma el pedido ni lo marca como enviado.
# "Pedido recibido" (Store::OrdersController) queda como respaldo: si el cliente vuelve a la tienda
# (atrás desde WhatsApp o reabre el checkout), el checkout lo lleva a esa pantalla.
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
  # Último pedido registrado en esta sesión y cuándo: volver al checkout poco después lleva a su
  # pantalla de "Pedido recibido" (respaldo) en vez de a un carrito vacío.
  RETURN_KEY = :retail_store_last_placed
  RETURN_WINDOW = 2.hours
  # Una caja con un sabor que ya no está disponible (u otra composición inválida) se corrige en el
  # carrito antes de finalizar; PlaceStoreOrder lo vuelve a validar igual.
  PROBLEMS_MESSAGE = "Hay cajas con sabores que ya no están disponibles. Corregilas antes de finalizar el pedido.".freeze

  def show
    # El checkout nunca se guarda en caché (tampoco en la caché de atrás/adelante del navegador): al
    # volver desde WhatsApp se pide de nuevo y lleva al pedido recién registrado.
    response.set_header("Cache-Control", "no-store")
    if store_cart.empty?
      recent = recently_placed_token
      return redirect_to(store_order_path(recent), status: :see_other) if recent

      return redirect_to(store_cart_path, status: :see_other)
    end
    return redirect_to(store_cart_path, status: :see_other, alert: PROBLEMS_MESSAGE) if store_cart.problems?

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
    return redirect_to(store_cart_path, status: :see_other, alert: PROBLEMS_MESSAGE) if store_cart.problems?

    @form = form_params
    if params[HONEYPOT].present?
      Rails.logger.info("[tienda] envío descartado por el campo trampa")
      return redirect_to(store_cart_path, status: :see_other, alert: "No pudimos procesar el pedido. Probá de nuevo.")
    end

    if form_token.blank? || form_token != session[TOKEN_KEY]
      @errors = ["El formulario se venció. Revisá los datos y tocá de nuevo «Finalizar pedido por WhatsApp»."]
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
    # Un reintento del mismo envío (doble toque que llegó tarde): el pedido ya existía; se muestra su
    # pantalla en vez de abrir WhatsApp otra vez.
    return redirect_to(store_order_path(order.public_token), status: :see_other) if result.duplicate?

    session[RETURN_KEY] = { "token" => order.public_token, "at" => Time.current.to_i }
    message = Retail::StoreWhatsappMessage.new(order, number: @store_setting.whatsapp_number)
    response.set_header("Referrer-Policy", "no-referrer") # wa.me no recibe la dirección de la tienda
    redirect_to message.url, allow_other_host: true, status: :see_other
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

  # Token del pedido registrado hace poco en esta sesión (para la pantalla de respaldo).
  def recently_placed_token
    data = session[RETURN_KEY]
    return nil unless data.is_a?(Hash) && data["token"].to_s.match?(/\A[A-Za-z0-9]{32}\z/)
    return nil if Time.current.to_i - data["at"].to_i > RETURN_WINDOW.to_i
    return nil unless Array(session[PLACED_KEY]).include?(data["token"])

    data["token"]
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
