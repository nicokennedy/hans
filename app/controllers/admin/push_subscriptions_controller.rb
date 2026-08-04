# Alta/baja/prueba de suscripciones Web Push. Solo admin y producción —
# los clientes nunca deben poder registrar ni recibir estas notificaciones
# internas. El user_id nunca sale de params: siempre es current_user, así
# que no hay mass assignment posible hacia otro usuario.
class Admin::PushSubscriptionsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_or_production!

  def create
    endpoint = subscription_params[:endpoint]

    if endpoint.blank? || subscription_params.dig(:keys, :p256dh).blank? || subscription_params.dig(:keys, :auth).blank?
      return render json: { error: "Suscripción incompleta." }, status: :unprocessable_entity
    end

    # Un mismo endpoint (dispositivo/navegador) puede haber quedado
    # registrado a nombre de otra persona si el dispositivo se comparte —
    # al registrarse de nuevo, la propiedad pasa a quien lo está activando
    # ahora. Esto es intencional: cerrar sesión no debe hacer que alguien
    # "herede" en silencio una suscripción ajena, pero un alta explícita sí
    # transfiere la suscripción a quien la está pidiendo.
    subscription = PushSubscription.find_or_initialize_by(endpoint: endpoint)
    subscription.user = current_user
    subscription.p256dh_key = subscription_params.dig(:keys, :p256dh)
    subscription.auth_key = subscription_params.dig(:keys, :auth)
    subscription.device_label = device_label_param

    begin
      if subscription.save
        render json: { id: subscription.id }, status: :ok
      else
        render json: { errors: subscription.errors.full_messages }, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotUnique
      # Dos registros simultáneos del mismo endpoint (poco común, pero
      # posible): la fila ya existe para este momento, así que la
      # actualizamos en vez de fallar.
      subscription = PushSubscription.find_by(endpoint: endpoint)
      subscription.update!(
        user: current_user,
        p256dh_key: subscription_params.dig(:keys, :p256dh),
        auth_key: subscription_params.dig(:keys, :auth),
        device_label: device_label_param
      )
      render json: { id: subscription.id }, status: :ok
    end
  end

  def destroy
    subscription = current_user.push_subscriptions.find(params[:id])
    subscription.destroy
    head :no_content
  end

  def test
    subscription = current_user.push_subscriptions.find(params[:id])

    result = Notifications::WebPushSender.deliver(subscription, test_payload)

    if result.delivered
      render json: { status: "sent" }, status: :ok
    else
      render json: { status: "failed", reason: result.error }, status: :unprocessable_entity
    end
  end

  private

  def subscription_params
    params.require(:subscription).permit(:endpoint, keys: [ :p256dh, :auth ])
  end

  def device_label_param
    params.dig(:subscription, :device_label).presence&.slice(0, 100)
  end

  def test_payload
    {
      title: "Notificación de prueba — HANS",
      body: "Si ves esto, las notificaciones están funcionando en este dispositivo.",
      tag: "hans-test-#{SecureRandom.hex(4)}",
      url: admin_push_settings_path,
      test: true,
      timestamp: Time.current.to_i * 1000
    }
  end
end
