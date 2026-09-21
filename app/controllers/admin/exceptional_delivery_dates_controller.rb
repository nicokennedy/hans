# Alta/baja de fechas excepcionales de entrega sobre el DeliverySetting
# singleton (ver DeliverySetting#add_exceptional_date!/#remove_exceptional_date!).
# No hay un modelo propio para estas fechas — viven como un array jsonb
# dentro de DeliverySetting, así que :id acá es directamente la fecha en
# formato ISO8601 ("2026-10-06"), no un id numérico.
class Admin::ExceptionalDeliveryDatesController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def create
    date = parse_date(params[:date])

    if date.nil?
      redirect_to admin_delivery_settings_path, alert: "Ingresá una fecha válida."
      return
    end

    if date < Date.current
      redirect_to admin_delivery_settings_path, alert: "No se puede habilitar una fecha pasada."
      return
    end

    # Idempotente: si ya estaba habilitada, no falla ni duplica — ver
    # DeliverySetting#add_exceptional_date!.
    DeliverySetting.current.add_exceptional_date!(date)
    redirect_to admin_delivery_settings_path, notice: "#{date.strftime('%d/%m/%Y')} habilitada como fecha de entrega."
  end

  def destroy
    date = parse_date(params[:id])

    if date.nil?
      redirect_to admin_delivery_settings_path, alert: "Fecha inválida."
      return
    end

    DeliverySetting.current.remove_exceptional_date!(date)
    redirect_to admin_delivery_settings_path, notice: "#{date.strftime('%d/%m/%Y')} ya no está habilitada por excepción."
  end

  private

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
