module RetailCatalogHelper
  def retail_catalog_money(cents)
    "$#{Retail::Money.format_pesos(cents)}"
  end

  # Miniatura optimizada (variante :thumb, WebP) o un recuadro "Sin foto" si todavía no hay.
  def retail_photo_thumb(photo, size: 64, variant: :thumb)
    if photo&.image&.attached?
      image_tag(url_for(photo.image.variant(variant)), alt: "", width: size, height: size, loading: "lazy", class: "rounded border object-fit-cover bg-light")
    else
      retail_photo_placeholder(size: size)
    end
  end

  def retail_photo_placeholder(size: 64)
    content_tag(:div, "Sin foto", class: "retail-photo-placeholder rounded border bg-light text-muted d-inline-flex align-items-center justify-content-center small",
                style: "width: #{size}px; height: #{size}px;", "aria-label": "Producto sin fotografía")
  end

  def retail_status_badges(product)
    badges = [content_tag(:span, product.active? ? "Activo" : "Inactivo", class: "badge #{product.active? ? 'bg-success' : 'bg-secondary'}")]
    badges << content_tag(:span, "Destacado", class: "badge text-bg-warning") if product.featured?
    badges << content_tag(:span, "Sin foto principal", class: "badge text-bg-light border text-danger") unless product.primary_photo
    safe_join(badges, " ")
  end
end
