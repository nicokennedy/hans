# Envía la Web Push de "pedido nuevo" a todos los dispositivos suscriptos
# autorizados (admin/producción). Se encola después del commit — nunca
# demora la creación del pedido — y recibe solo el id, nunca el objeto
# Order serializado, para volver a buscarlo fresco al momento de correr.
class PushNotificationJob < ApplicationJob
  queue_as :default

  def perform(order_id)
    unless Notifications::WebPushVapid.configured?
      Rails.logger.error("[PushNotificationJob] VAPID no está configurado (faltan WEB_PUSH_VAPID_* en el entorno) — no se envía ninguna push.")
      return
    end

    order = Order.find_by(id: order_id)
    return if order.nil? # el pedido pudo haberse borrado entre el commit y la ejecución del job

    payload = build_payload(order)

    PushSubscription.eligible_for_order_notifications.find_each do |subscription|
      Notifications::WebPushSender.deliver(subscription, payload)
    end
  end

  private

  def build_payload(order)
    {
      title: "Nuevo pedido HANS",
      body: "Pedido #{order.number} — #{order.customer.name}",
      tag: "order-#{order.id}",
      url: Rails.application.routes.url_helpers.admin_order_path(order),
      order_id: order.id,
      timestamp: order.created_at.to_i * 1000
    }
  end
end
