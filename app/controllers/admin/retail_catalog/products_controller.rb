# Productos del catálogo minorista (Tienda Minorista → Productos). No toca productos, precios ni
# stock mayoristas: el vínculo con un producto mayorista es opcional y solo se guarda.
class Admin::RetailCatalog::ProductsController < Admin::RetailCatalog::BaseController
  STATUS_FILTERS = {
    "active" => "Activos", "inactive" => "Inactivos", "ready" => "Listos para publicar", "missing_photo" => "Sin foto principal"
  }.freeze
  SORTS = {
    "position" => "Orden", "name" => "Nombre", "price_asc" => "Precio: menor a mayor", "price_desc" => "Precio: mayor a menor", "updated" => "Última modificación"
  }.freeze

  before_action :set_product, only: [:show, :edit, :update, :destroy, :toggle_active, :duplicate, :move_up, :move_down]
  before_action :load_form_options, only: [:new, :create, :edit, :update]

  def index
    @query = params[:q].is_a?(String) ? params[:q].squish.first(100).presence : nil
    @category_id = params[:category_id].to_s.match?(/\A\d+\z/) ? params[:category_id].to_i : nil
    @status = STATUS_FILTERS.key?(params[:status]) ? params[:status] : nil
    @sort = SORTS.key?(params[:sort]) ? params[:sort] : "position"
    @categories = RetailCategory.ordered.to_a
    @products = filtered_products.includes(:retail_category, :product, primary_photo: { image_attachment: :blob }).to_a
    @total_count = RetailProduct.count
  end

  def show
    @photos = @product.photos.includes(image_attachment: :blob).to_a
  end

  def new
    @product = RetailProduct.new(position: (RetailProduct.maximum(:position) || 0) + 1, active: false, retail_category: @categories.find(&:active?))
  end

  def create
    @product = RetailProduct.new(product_params)
    if @product.save
      redirect_to admin_retail_catalog_product_path(@product), notice: "Producto creado. Ahora podés agregarle fotos."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @product.update(product_params)
      redirect_to admin_retail_catalog_product_path(@product), notice: "Producto actualizado."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_active
    @product.update!(active: !@product.active?)
    notice = @product.active? ? "Producto activado." : "Producto desactivado."
    notice += " Todavía no está listo para la tienda: #{@product.publication_issues.join(', ').downcase}." if @product.active? && !@product.ready_for_store?
    redirect_back fallback_location: admin_retail_catalog_products_path, notice: notice
  end

  def duplicate
    copy = @product.duplicate
    copy.save!
    redirect_to edit_admin_retail_catalog_product_path(copy), notice: "Copia creada (inactiva y sin fotos). Revisá el nombre y el precio."
  end

  def destroy
    unless @product.deletable?
      return redirect_to admin_retail_catalog_product_path(@product), alert: "Desactivá el producto antes de eliminarlo."
    end

    @product.destroy!
    redirect_to admin_retail_catalog_products_path, notice: "Producto “#{@product.name}” eliminado."
  end

  def move_up
    move(-1)
  end

  def move_down
    move(1)
  end

  private

  def set_product
    @product = RetailProduct.find(params[:id])
  end

  def load_form_options
    @categories = RetailCategory.ordered.to_a
    @wholesale_products = Product.order(Arel.sql("lower(name)")).pluck(:name, :id, :active)
  end

  def product_params
    permitted = params.require(:retail_product).permit(:name, :code, :description, :price, :retail_category_id, :product_id, :active, :featured, :position)
    permitted[:product_id] = nil if permitted[:product_id].blank?
    permitted
  end

  def filtered_products
    scope = RetailProduct.all
    scope = scope.where("retail_products.name ILIKE :q OR retail_products.code ILIKE :q", q: "%#{RetailProduct.sanitize_sql_like(@query)}%") if @query
    scope = scope.where(retail_category_id: @category_id) if @category_id
    with_primary = RetailProductPhoto.where(primary: true).select(:retail_product_id)
    scope = case @status
            when "active" then scope.where(active: true)
            when "inactive" then scope.where(active: false)
            when "ready" then scope.where(active: true, id: with_primary).joins(:retail_category).where(retail_categories: { active: true })
            when "missing_photo" then scope.where.not(id: with_primary)
            else scope
            end
    case @sort
    when "name" then scope.order(Arel.sql("lower(retail_products.name)"), :id)
    when "price_asc" then scope.order(:price_cents, :id)
    when "price_desc" then scope.order(price_cents: :desc, id: :asc)
    when "updated" then scope.order(updated_at: :desc, id: :desc)
    else scope.ordered
    end
  end

  # Reordena todo el catálogo 1..n intercambiando el producto con su vecino.
  def move(direction)
    RetailProduct.transaction do
      ordered = RetailProduct.lock.ordered.to_a
      index = ordered.index(@product)
      target = index + direction
      if target.between?(0, ordered.size - 1)
        ordered[index], ordered[target] = ordered[target], ordered[index]
        ordered.each_with_index { |p, i| p.update_columns(position: i + 1) if p.position != i + 1 }
      end
    end
    redirect_back fallback_location: admin_retail_catalog_products_path
  end
end
