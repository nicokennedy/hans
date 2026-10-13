module RetailOrdersHelper
  def retail_money(cents)
    "$#{Retail::Money.format_pesos(cents)}"
  end

  def retail_status_options
    RetailOrder::STATUS_LABELS.map { |value, label| [label, value] }
  end

  def retail_payment_status_options
    RetailOrder::PAYMENT_STATUS_LABELS.map { |value, label| [label, value] }
  end

  def retail_delivery_kind_options
    RetailOrder::DELIVERY_KIND_LABELS.map { |value, label| [label, value] }
  end

  def retail_payment_method_options
    RetailOrder::PAYMENT_METHOD_LABELS.map { |value, label| [label, value] }
  end

  def retail_status_badge(order)
    tone = { "pending" => "secondary", "in_preparation" => "warning", "ready" => "info", "delivered" => "success", "canceled" => "dark" }[order.status]
    content_tag(:span, order.status_label, class: "badge text-bg-#{tone}")
  end

  def retail_payment_badge(order)
    tone = { "pending" => "danger", "partial" => "warning", "paid" => "success" }[order.payment_status]
    content_tag(:span, order.payment_status_label, class: "badge text-bg-#{tone}")
  end

  def retail_date(date)
    date&.strftime("%d/%m/%Y")
  end

  def retail_whatsapp_link(order)
    return order.buyer_phone.presence if order.whatsapp_url.nil?

    link_to(order.buyer_phone, order.whatsapp_url, target: "_blank", rel: "noopener", title: "Abrir WhatsApp")
  end

  # Link a la página indicada del listado conservando los filtros actuales.
  def retail_list_path(overrides = {})
    admin_retail_orders_path(retail_context.except(:page).merge(overrides.compact))
  end
end
