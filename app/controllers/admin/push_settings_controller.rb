# Pantalla de "Notificaciones de pedidos" para admin y producción. Los
# clientes no tienen acceso (mismo before_action que el resto del admin).
class Admin::PushSettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_or_production!

  def show
    @vapid_public_key = Notifications::WebPushVapid.public_key
    @server_configured = Notifications::WebPushVapid.configured?
  end
end
