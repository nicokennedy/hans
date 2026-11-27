module RepartoHelper
  DAY_NAMES = %w[Domingo Lunes Martes Miércoles Jueves Viernes Sábado].freeze
  MONTH_NAMES = %w[enero febrero marzo abril mayo junio julio agosto septiembre octubre noviembre diciembre].freeze

  def reparto_money(cents)
    "$#{CustomerAccounts::Money.format_pesos(cents)}"
  end

  # "Miércoles 18 de noviembre". Los archivos de idioma de HANS no traen nombres de días ni
  # meses, así que se arma acá en vez de usar l(date).
  def reparto_date(date)
    "#{DAY_NAMES[date.wday]} #{date.day} de #{MONTH_NAMES[date.month - 1]}"
  end
end
