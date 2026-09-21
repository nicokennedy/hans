# Pantalla de administración de DeliverySetting. Por ahora solo expone las
# fechas excepcionales de entrega (ver Admin::ExceptionalDeliveryDatesController)
# — a propósito NO expone unavailable_weekdays/cutoff_hour como
# configuración editable en esta tarea, esos siguen siendo fijos.
class Admin::DeliverySettingsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def show
    @delivery_setting = DeliverySetting.current
    @exceptional_dates = @delivery_setting.exceptional_dates.sort
  end
end
