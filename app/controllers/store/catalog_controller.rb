# Catálogo público: solo productos publicados (activos, de categoría activa y con foto principal),
# agrupados por categoría en el orden que se configura en Tienda Minorista.
#
# Orden de la página: encabezado (logo y navegación) → «Nuestras especialidades» (arcos de
# categorías) → información comercial (retiro, envío, anticipación, WhatsApp) → navegación por
# categorías → catálogo. La portada (hero) ya no se muestra; sus datos siguen en RetailStoreSetting.
class Store::CatalogController < Store::BaseController
  def index
    products = RetailProduct.for_store.includes(:retail_category, :variants, :flavors, primary_photo: { image_attachment: :blob }).ordered.to_a
    @categories = products.group_by(&:retail_category).sort_by { |category, _| [category.position, category.name.downcase, category.id] }
    @featured = products.select(&:featured?).first(8)
    @fulfillment = RetailFulfillment::Options.call
  end

  def show
    @product = RetailProduct.for_store.includes(:retail_category, :variants, :flavors, photos: { image_attachment: :blob }).find_by(id: params[:id].to_i)
    return render("store/not_found", status: :not_found) unless @product

    @photos = @product.photos.to_a
    @fulfillment = RetailFulfillment::Options.call
    @editing = editing_box
  end

  private

  # "Cambiar sabores" desde el carrito (?editar=<clave de la línea>): la caja de ESTE producto que
  # está en el carrito, con su variante y su composición para precargar el selector. Si la línea ya no
  # está o es de otro producto, el detalle se abre normal.
  def editing_box
    return nil unless @product.customizable_content?

    key = params[:editar].to_s
    return nil unless store_cart.contents.key?(key)

    variant_id, quantities = Retail::BoxComposition.parse_key(key)
    variant = @product.variants.find { |v| v.id == variant_id && v.purchasable? }
    return nil unless variant

    active_ids = @product.active_flavors.map(&:id)
    { key: key, variant: variant, quantities: Hash(quantities).slice(*active_ids) }
  end
end
