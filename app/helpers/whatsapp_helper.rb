module WhatsappHelper
  def whatsapp_order_link_url(order)
    message = Notifications::OrderWhatsappMessage.new(order, admin_order_url(order))
    Notifications::WhatsappLink.build(message.to_s)
  end

  def whatsapp_link_url(text)
    Notifications::WhatsappLink.build(text)
  end
end
