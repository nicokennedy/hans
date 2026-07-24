module ApplicationHelper
  # Formato monetario centralizado (formato argentino, sin decimales) para
  # no repetir "$#{number_with_delimiter(cents / 100)}" en cada vista.
  def format_money(cents)
    "$#{number_with_delimiter(cents.to_i / 100)}"
  end
end
