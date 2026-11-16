module StoreHelper
  def store_money(cents)
    "$#{Retail::Money.format_pesos(cents)}"
  end

  # Fotos de la tienda: siempre una versión optimizada (card 600×600 o detail hasta 1200 px, WebP),
  # nunca el original. Se sirven a través de HANS en modo proxy (Active Storage), con caché pública
  # de larga duración: el bucket de R2 sigue privado y no hay URLs firmadas que venzan en el catálogo.
  def store_photo_url(photo, variant = :card)
    rails_storage_proxy_path(photo.image.variant(variant))
  end

  def store_photo_tag(photo, variant: :card, alt: "", **options)
    return content_tag(:div, "", class: "store-photo-empty", "aria-hidden": true) unless photo&.image&.attached?

    image_tag(store_photo_url(photo, variant), alt: alt, loading: options.delete(:loading) || "lazy", decoding: "async", **options)
  end

  def store_product_path_for(product)
    store_product_path(id: store_product_slug(product))
  end

  # "Tamaño" para tortas (variantes en cm); "Presentación" para cajas, boxes, etc.
  def store_variant_kind(variants)
    variants.all? { |v| v.name.to_s.match?(/\d\s*cm\b/i) } ? "Tamaño" : "Presentación"
  end

  def store_date(date)
    RetailFulfillment.format_date(date).sub(/\A./, &:upcase)
  end

  # "Lunes a viernes: 14:00 a 17:00 hs · sábado: 11:00 a 13:00 hs" (días seguidos con la misma franja
  # se agrupan). weekly: lo que arma RetailFulfillment::Options.
  def store_weekly_summary(weekly)
    order = RetailServiceWindow::WEEK_ORDER
    groups = weekly.chunk_while { |a, b| a[:label] == b[:label] && order.index(b[:wday]) == order.index(a[:wday]) + 1 }
    text = groups.map do |group|
      days = group.size > 1 ? "#{group.first[:day].downcase} a #{group.last[:day].downcase}" : group.first[:day].downcase
      "#{days}: #{group.first[:label]}"
    end.join(" · ")
    text.sub(/\A./, &:upcase)
  end

  STORE_ICONS = {
    bag: '<path d="M5.5 8h13l-1.1 12.2a1 1 0 0 1-1 .8H7.6a1 1 0 0 1-1-.8L5.5 8z"/><path d="M9 10V7a3 3 0 0 1 6 0v3"/>',
    pin: '<path d="M12 21s-6.5-5.6-6.5-11a6.5 6.5 0 0 1 13 0c0 5.4-6.5 11-6.5 11z"/><circle cx="12" cy="10" r="2.3"/>',
    truck: '<path d="M3 6.5h10.5v9.5H3z"/><path d="M13.5 10h4l3 3.2V16h-7"/><circle cx="7" cy="17.5" r="1.8"/><circle cx="17" cy="17.5" r="1.8"/>',
    calendar: '<rect x="4" y="5.5" width="16" height="14.5" rx="2"/><path d="M4 10h16M8.5 3.5v4M15.5 3.5v4"/>',
    arrow_right: '<path d="M5 12h14M13 6l6 6-6 6"/>',
    arrow_left: '<path d="M19 12H5M11 6l-6 6 6 6"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
    chat: '<path d="M4.5 18.5l1.2-3.6A7.5 7.5 0 1 1 9 18.1l-4.5.4z"/>',
    sparkle: '<path d="M12 3.5l1.8 5.2 5.2 1.8-5.2 1.8L12 17.5l-1.8-5.2L5 10.5l5.2-1.8z"/>',
    card: '<rect x="3.5" y="6" width="17" height="12" rx="2"/><path d="M3.5 10h17"/>',
    cash: '<rect x="3.5" y="6.5" width="17" height="11" rx="2"/><circle cx="12" cy="12" r="2.3"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>'
  }.freeze

  # Íconos de línea de la tienda (SVG en línea, trazo fino, color heredado).
  def store_icon(name, size: 20, stroke: 1.5, **options)
    content_tag(:svg, STORE_ICONS.fetch(name).html_safe, xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 24 24", width: size, height: size,
      fill: "none", stroke: "currentColor", "stroke-width": stroke, "stroke-linecap": "round", "stroke-linejoin": "round",
      "aria-hidden": true, focusable: "false", class: ["store-icon", options[:class]].compact.join(" "))
  end

  # Ícono de WhatsApp (SVG en línea, sin dependencias externas).
  def store_whatsapp_icon(size: 22)
    content_tag(:svg, tag.path(d: "M16 3C8.8 3 3 8.7 3 15.8c0 2.5.7 4.9 2 7L3 29l6.4-2a13.2 13.2 0 0 0 6.6 1.7c7.2 0 13-5.8 13-12.9C29 8.7 23.2 3 16 3zm0 23.4c-2.1 0-4.1-.6-5.9-1.6l-.4-.2-3.8 1.2 1.2-3.7-.3-.4a10.5 10.5 0 0 1-1.7-5.8C5.1 9.9 10 5.2 16 5.2s10.9 4.7 10.9 10.6S22 26.4 16 26.4zm6-7.9c-.3-.2-1.9-1-2.2-1.1-.3-.1-.5-.2-.7.2-.2.3-.8 1-1 1.2-.2.2-.4.2-.7.1-.3-.2-1.4-.5-2.6-1.6-1-.9-1.6-1.9-1.8-2.2-.2-.3 0-.5.1-.7l.5-.6c.2-.2.2-.3.3-.6.1-.2 0-.4 0-.6l-1-2.4c-.3-.6-.5-.5-.7-.5h-.6c-.2 0-.6.1-.9.4-.3.3-1.2 1.1-1.2 2.8s1.2 3.2 1.4 3.4c.2.2 2.4 3.6 5.7 5 .8.3 1.4.5 1.9.7.8.3 1.5.2 2.1.1.6-.1 1.9-.8 2.2-1.5.3-.7.3-1.4.2-1.5-.1-.2-.3-.3-.6-.4z", fill: "currentColor"),
      xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 32 32", width: size, height: size, "aria-hidden": true, focusable: "false")
  end
end
