module ApplicationHelper
  # Formato monetario centralizado (formato argentino, sin decimales) para
  # no repetir "$#{number_with_delimiter(cents / 100)}" en cada vista.
  def format_money(cents)
    "$#{number_with_delimiter(cents.to_i / 100)}"
  end

  # Cantidad decimal sin ceros de relleno (25.000 -> "25", 0.500 -> "0.5")
  # — mismo criterio que RawMaterial#purchase_format, centralizado acá para
  # no reimplementarlo en cada vista que muestra cantidad+unidad
  # (Preparation#yield_quantity, RecipeComponent#quantity).
  def format_quantity(quantity)
    quantity.to_d.to_s("F").sub(/0+\z/, "").sub(/\.\z/, "")
  end

  def format_quantity_unit(quantity, unit)
    "#{format_quantity(quantity)} #{unit}"
  end
end
