# "Pedido recibido": la pantalla del cliente después de registrar el pedido, con el número, el
# resumen y el botón para abrir WhatsApp con el mensaje armado desde el pedido guardado.
#
# Acceso: solo con el public_token (32 caracteres aleatorios, nunca el id). Se puede reabrir las
# veces que haga falta (recarga, volver desde WhatsApp) sin crear otro pedido. Para no dejar datos
# personales a la vista indefinidamente, el enlace deja de mostrar el pedido 30 días después de la
# fecha de entrega. No se cachea, no se indexa y no envía el Referer a WhatsApp.
class Store::OrdersController < Store::BaseController
  VISIBLE_DAYS_AFTER_DELIVERY = 30

  skip_before_action :require_open_store # quien ya hizo su pedido lo ve aunque la tienda se cierre

  def show
    @order = RetailOrder.source_store.includes(:retail_order_items).find_by(public_token: params[:token].to_s)
    if @order.nil? || @order.delivery_date < RetailFulfillment.today - VISIBLE_DAYS_AFTER_DELIVERY
      return render("store/not_found", status: :not_found)
    end

    message = Retail::StoreWhatsappMessage.new(@order, number: store_setting.whatsapp_number)
    @whatsapp_url = message.url
    @whatsapp_text = message.text
    @open_whatsapp = flash[:store_open_whatsapp].present?
    @pickup_details = RetailFulfillmentSetting.current.pickup_point_details if @order.pickup?

    response.set_header("Cache-Control", "no-store")
    response.set_header("Referrer-Policy", "no-referrer")
    response.set_header("X-Robots-Tag", "noindex, nofollow")
  end
end
