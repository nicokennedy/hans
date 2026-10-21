module CustomerAccountsHelper
  def account_money(cents)
    "$#{CustomerAccounts::Money.format_pesos(cents)}"
  end

  def account_order_status(order)
    return ["Pagado", "bg-success"] if order.balance_due_cents <= 0 && order.amount_paid_cents.to_i.positive?
    return ["Parcial", "bg-warning text-dark"] if order.amount_paid_cents.to_i.positive?

    ["Pendiente", "bg-secondary"]
  end

  def account_filter_path(customer, summary, filter)
    admin_customer_account_path(customer, customers_context.list_query.merge({ via: customers_context.via, filter: (filter unless filter == "all"), from: summary.from&.iso8601, to: summary.to&.iso8601 }.compact))
  end

  # Campos ocultos con el contexto de Clientes, para que los formularios de la cuenta
  # corriente (pagos, saldo a favor, anulaciones, filtros) lo devuelvan al guardar.
  def customers_context_hidden_fields(query = customers_context.account_query)
    safe_join(query.map { |key, value| hidden_field_tag(key, value, id: nil) })
  end
end
