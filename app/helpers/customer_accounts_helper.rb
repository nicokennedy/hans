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
    admin_customer_account_path(customer, { filter: (filter unless filter == "all"), from: summary.from&.iso8601, to: summary.to&.iso8601 }.compact)
  end
end
