module Notifications
  # Único punto que llama a la gema web-push. Lo usan tanto el job de
  # pedidos reales como la acción de "enviar notificación de prueba", para
  # no duplicar el manejo de errores/expiración en dos lugares.
  class WebPushSender
    Result = Struct.new(:delivered, :expired, :error, keyword_init: true)

    def self.deliver(subscription, payload_hash)
      new(subscription, payload_hash).deliver
    end

    def initialize(subscription, payload_hash)
      @subscription = subscription
      @payload_hash = payload_hash
    end

    def deliver
      return Result.new(delivered: false, expired: false, error: "vapid_not_configured") unless Notifications::WebPushVapid.configured?

      WebPush.payload_send(
        message: payload_hash.to_json,
        endpoint: subscription.endpoint,
        p256dh: subscription.p256dh_key,
        auth: subscription.auth_key,
        vapid: Notifications::WebPushVapid.vapid_options,
        ttl: 60 * 60
      )
      Result.new(delivered: true, expired: false, error: nil)
    rescue WebPush::ExpiredSubscription, WebPush::InvalidSubscription
      # 410/404: el navegador o el usuario revocaron esta suscripción
      # puntual. Es seguro borrarla, no afecta a los demás dispositivos.
      Rails.logger.info("[WebPushSender] eliminando suscripción vencida id=#{subscription.id}")
      subscription.destroy
      Result.new(delivered: false, expired: true, error: "expired_subscription")
    rescue WebPush::Unauthorized => e
      # 401/403: casi siempre una clave VAPID mal configurada, no un
      # problema de este dispositivo puntual — no borrar la suscripción.
      Rails.logger.error("[WebPushSender] error de autorización VAPID para suscripción id=#{subscription.id}: #{e.class}")
      Result.new(delivered: false, expired: false, error: "vapid_unauthorized")
    rescue WebPush::Error => e
      # Errores transitorios (5xx, 429, payload demasiado grande, etc.): se
      # loguean sin exponer claves ni el cuerpo del payload y NO se borra la
      # suscripción — un fallo pasajero del servicio push no amerita dejar
      # de notificar a ese dispositivo en el futuro.
      Rails.logger.error("[WebPushSender] fallo temporal enviando a suscripción id=#{subscription.id}: #{e.class}")
      Result.new(delivered: false, expired: false, error: "transient_error")
    end

    private

    attr_reader :subscription, :payload_hash
  end
end
