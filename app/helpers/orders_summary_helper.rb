module OrdersSummaryHelper
  # Período del resumen de Pedidos / Pedidos Minoristas, con la misma regla que sus filtros de
  # fecha de entrega: solo "desde" es ese día; "desde" y "hasta", el rango; solo "hasta", hasta ese día.
  def orders_summary_period_label(from, to)
    if from && to
      first, last = [from, to].minmax
      first == last ? first.strftime("%d/%m/%Y") : "#{first.strftime('%d/%m/%Y')} – #{last.strftime('%d/%m/%Y')}"
    elsif from
      from.strftime("%d/%m/%Y")
    elsif to
      "hasta #{to.strftime('%d/%m/%Y')}"
    else
      "Todos"
    end
  end

  # Pesos sin decimales innecesarios: $1.500 / $1.500,50 / $0.
  def orders_summary_money(cents)
    "$#{CustomerAccounts::Money.format_pesos(cents)}"
  end
end
