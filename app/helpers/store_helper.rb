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

  # Ícono de WhatsApp (SVG en línea, sin dependencias externas).
  def store_whatsapp_icon(size: 22)
    content_tag(:svg, tag.path(d: "M16 3C8.8 3 3 8.7 3 15.8c0 2.5.7 4.9 2 7L3 29l6.4-2a13.2 13.2 0 0 0 6.6 1.7c7.2 0 13-5.8 13-12.9C29 8.7 23.2 3 16 3zm0 23.4c-2.1 0-4.1-.6-5.9-1.6l-.4-.2-3.8 1.2 1.2-3.7-.3-.4a10.5 10.5 0 0 1-1.7-5.8C5.1 9.9 10 5.2 16 5.2s10.9 4.7 10.9 10.6S22 26.4 16 26.4zm6-7.9c-.3-.2-1.9-1-2.2-1.1-.3-.1-.5-.2-.7.2-.2.3-.8 1-1 1.2-.2.2-.4.2-.7.1-.3-.2-1.4-.5-2.6-1.6-1-.9-1.6-1.9-1.8-2.2-.2-.3 0-.5.1-.7l.5-.6c.2-.2.2-.3.3-.6.1-.2 0-.4 0-.6l-1-2.4c-.3-.6-.5-.5-.7-.5h-.6c-.2 0-.6.1-.9.4-.3.3-1.2 1.1-1.2 2.8s1.2 3.2 1.4 3.4c.2.2 2.4 3.6 5.7 5 .8.3 1.4.5 1.9.7.8.3 1.5.2 2.1.1.6-.1 1.9-.8 2.2-1.5.3-.7.3-1.4.2-1.5-.1-.2-.3-.3-.6-.4z", fill: "currentColor"),
      xmlns: "http://www.w3.org/2000/svg", viewBox: "0 0 32 32", width: size, height: size, "aria-hidden": true, focusable: "false")
  end
end
