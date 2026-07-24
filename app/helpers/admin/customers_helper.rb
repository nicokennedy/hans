module Admin::CustomersHelper
  def collections_percent(invoiced_cents, paid_cents)
    return nil if invoiced_cents.to_i <= 0

    ((paid_cents.to_i / invoiced_cents.to_f) * 100).round
  end

  def collections_status_label(invoiced_cents, paid_cents)
    return "—" if invoiced_cents.to_i <= 0

    (invoiced_cents.to_i - paid_cents.to_i) <= 0 ? "Al día" : "Saldo pendiente"
  end
end
