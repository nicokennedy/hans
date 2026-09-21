module Admin::DeliverySettingsHelper
  # "Martes 06/10/2026" — usa es.date.day_names (ya configurado en
  # config/locales/es.yml) en vez de duplicar nombres de día acá.
  def exceptional_date_label(date)
    I18n.l(date, format: "%A %d/%m/%Y")
  end
end
