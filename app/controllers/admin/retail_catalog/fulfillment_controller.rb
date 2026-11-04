# Tienda Minorista → Entregas: reglas de retiro por zona Plaza del Agua y envío a domicilio
# (anticipación, punto de retiro, días y franjas, zonas y fechas sin servicio), más un simulador
# que muestra qué vería el cliente. Solo admin. Independiente del reparto mayorista.
class Admin::RetailCatalog::FulfillmentController < Admin::RetailCatalog::BaseController
  before_action :set_setting

  def show
    load_page
  end

  def general
    if @setting.update(params.require(:retail_fulfillment_setting).permit(:min_lead_days, :pickup_point_details))
      redirect_to admin_retail_catalog_fulfillment_path, notice: "Reglas generales actualizadas."
    else
      @general_errors = @setting.errors.full_messages
      load_page
      render :show, status: :unprocessable_entity
    end
  end

  # Guarda los 14 días (7 por modalidad) juntos: si alguno es inválido no se cambia ninguno.
  def schedule
    input = params.fetch(:windows, {})
    windows = RetailServiceWindow.order(:service, :wday).to_a
    errors = []

    RetailServiceWindow.transaction do
      windows.each do |window|
        row = input.dig(window.service, window.wday.to_s) || {}
        window.enabled = row[:enabled] == "1"
        { opens_minute: row[:opens_at], closes_minute: row[:closes_at] }.each do |attribute, text|
          next window[attribute] = nil if text.blank? && !window.enabled?

          minute = RetailServiceWindow.parse_minute(text)
          if text.present? && minute.nil?
            errors << "#{RetailFulfillment.service_name(window.service)}, #{window.day_name}: la hora \"#{text}\" no es válida (usá HH:MM)."
          else
            window[attribute] = minute
          end
        end
        errors.concat(window.errors.full_messages.map { |m| "#{RetailFulfillment.service_name(window.service)}, #{m}" }) unless window.valid?
      end
      raise ActiveRecord::Rollback if errors.any?

      windows.each(&:save!)
    end

    if errors.empty?
      redirect_to admin_retail_catalog_fulfillment_path(anchor: "horarios"), notice: "Días y horarios actualizados."
    else
      @schedule_errors = errors.uniq
      @windows_override = windows
      load_page
      render :show, status: :unprocessable_entity
    end
  end

  private

  def set_setting
    @setting = RetailFulfillmentSetting.current
  end

  def load_page
    @calendar = RetailFulfillment::Calendar.new(setting: @setting)
    @windows = (@windows_override || RetailServiceWindow.all.to_a).group_by(&:service)
      .transform_values { |list| list.sort_by { |w| RetailServiceWindow::WEEK_ORDER.index(w.wday) } }
    @zones = RetailDeliveryZone.ordered.to_a
    @zone_usage = RetailOrder.where.not(delivery_zone_id: nil).group(:delivery_zone_id).count
    @closures = RetailServiceClosure.upcoming(@calendar.today).includes(:created_by).to_a
    @closure = RetailServiceClosure.new(service: "all")
    @next_dates = RetailServiceWindow::SERVICES.index_with { |service| @calendar.available_dates(service).first(8) }
    prepare_preview
  end

  # Simulador: misma validación que hará el checkout (RetailFulfillment::Quote), sin crear nada.
  def prepare_preview
    @preview = params.fetch(:preview, {}).permit(:service, :date, :zone_id, :subtotal).to_h.symbolize_keys
    return if @preview[:service].blank?

    subtotal = @preview[:subtotal].present? ? Retail::Money.parse_pesos(@preview[:subtotal]) : 0
    @preview_quote = RetailFulfillment::Quote.call(service: @preview[:service], date: @preview[:date], zone_id: @preview[:zone_id],
      address: "Dirección de prueba", subtotal_cents: subtotal || -1, calendar: @calendar)
  end
end
