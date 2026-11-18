module Admin::DeliveryRoutesHelper
  # Dirección de un cliente o parada, o un aviso visible si no tiene (nunca se inventa).
  def delivery_address_cell(address, maps_url: nil, instructions: nil)
    if address.present?
      parts = [content_tag(:span, address)]
      parts << link_to("Mapa", maps_url, target: "_blank", rel: "noopener", class: "small ms-1") if maps_url
      parts << content_tag(:div, instructions, class: "small text-muted") if instructions.present?
      safe_join(parts, " ")
    else
      content_tag(:span, "⚠ Sin dirección cargada", class: "badge text-bg-warning")
    end
  end

  def customer_address_line(customer)
    [customer.address, customer.address_unit].map { |v| v.to_s.strip.presence }.compact.join(" · ").presence
  end

  def delivery_route_status_badge(route)
    content_tag(:span, route.status_label, class: "badge #{route.editable? ? 'text-bg-secondary' : 'text-bg-success'}")
  end
end
