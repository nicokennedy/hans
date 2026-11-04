require "erb"

module Retail
  # Mensaje prearmado que el cliente le manda a HANS por WhatsApp después de registrar su pedido en
  # la tienda. Se arma SIEMPRE desde el pedido guardado (productos, importes, entrega y datos tal
  # como quedaron en la base), nunca desde lo que mandó el navegador.
  #
  # El enlace es https://wa.me/<número>?text=<mensaje codificado>: abre WhatsApp (app o web) con el
  # mensaje listo para enviar. No hay API de WhatsApp ni webhooks: HANS no puede saber si el mensaje
  # se envió, así que la tienda nunca lo afirma. El pedido ya está registrado antes de abrir el enlace.
  class StoreWhatsappMessage
    def initialize(order, number: RetailStoreSetting.current.whatsapp_number, preview: false)
      @order = order
      @number = number.to_s.gsub(/\D/, "")
      @preview = preview
    end

    def text
      lines = []
      lines << "[VISTA PREVIA DE PRUEBA: este pedido no se registró]" if @preview
      lines << "Hola HANS! 🍰 Quiero confirmar mi pedido #{@order.persisted? ? "##{@order.number}" : '(número de prueba)'}."
      lines << ""
      lines << "Productos:"
      @order.retail_order_items.each do |item|
        lines << "• #{item.quantity} × #{item.display_name} — #{money(item.line_total_cents)}"
      end
      lines << ""
      lines << "Subtotal: #{money(@order.subtotal_cents)}"
      lines << "Envío: #{@order.shipping_cents.zero? ? 'Gratis' : money(@order.shipping_cents)}"
      lines << "Total: #{money(@order.total_cents)}"
      lines << ""
      lines << "Nombre: #{@order.buyer_name}"
      lines << "Teléfono: #{@order.buyer_phone}"
      lines << "Email: #{@order.buyer_email}" if @order.buyer_email.present?
      lines << "Modalidad: #{@order.delivery_service_name}"
      if @order.delivery?
        lines << "Zona: #{@order.delivery_zone_name}" if @order.delivery_zone_name.present?
        lines << "Dirección: #{@order.address}" if @order.address.present?
      end
      lines << "Fecha: #{RetailFulfillment.format_date(@order.delivery_date)}"
      lines << "Horario: #{@order.delivery_window_label}" if @order.delivery_window_label.present?
      lines << "Forma de pago: #{@order.store_payment_method_label}" if @order.planned_payment_method.present?
      lines << "Observaciones: #{@order.notes}" if @order.notes.present?
      lines << ""
      lines << "Quedo a la espera de la confirmación. ¡Gracias!"
      lines.join("\n")
    end

    def url
      "https://wa.me/#{@number}?text=#{ERB::Util.url_encode(text)}"
    end

    private

    def money(cents)
      "$#{Retail::Money.format_pesos(cents)}"
    end
  end
end
