# Catálogo público: solo productos publicados (activos, de categoría activa y con foto principal),
# agrupados por categoría en el orden que se configura en Tienda Minorista.
class Store::CatalogController < Store::BaseController
  def index
    products = RetailProduct.for_store.includes(:retail_category, primary_photo: { image_attachment: :blob }).ordered.to_a
    @categories = products.group_by(&:retail_category).sort_by { |category, _| [category.position, category.name.downcase, category.id] }
    @featured = products.select(&:featured?).first(8)
    @fulfillment = RetailFulfillment::Options.call
  end

  def show
    @product = RetailProduct.for_store.includes(:retail_category, photos: { image_attachment: :blob }).find_by(id: params[:id].to_i)
    return render("store/not_found", status: :not_found) unless @product

    @photos = @product.photos.to_a
  end
end
