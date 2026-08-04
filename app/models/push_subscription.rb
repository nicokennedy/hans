# Una fila por dispositivo/navegador suscripto a Web Push. El endpoint
# (URL única que asigna el navegador) identifica al dispositivo — nunca
# el user_id solo, porque una misma persona puede tener varios dispositivos
# y un mismo dispositivo puede pasar de mano en mano (ver alta idempotente
# y el flujo de logout más abajo).
class PushSubscription < ApplicationRecord
  belongs_to :user

  validates :endpoint, presence: true, uniqueness: true
  validates :p256dh_key, :auth_key, presence: true

  # Solo admin/producción pueden recibir notificaciones internas de pedidos.
  # Chequeo defensivo además del control en el controller: si un usuario
  # cambia de rol después de crear la suscripción, deja de recibir envíos
  # sin necesidad de una migración de datos.
  scope :eligible_for_order_notifications, -> {
    joins(:user).where(users: { role: %w[admin production] })
  }

  def to_web_push_subscription
    {
      endpoint: endpoint,
      keys: { p256dh: p256dh_key, auth: auth_key }
    }
  end
end
