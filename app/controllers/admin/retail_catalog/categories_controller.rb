# Categorías del catálogo minorista: alta, edición, activar/desactivar, orden y borrado solo si no
# tienen productos (si los tienen, se desactivan).
class Admin::RetailCatalog::CategoriesController < Admin::RetailCatalog::BaseController
  before_action :set_category, only: [:edit, :update, :destroy, :toggle_active, :move_up, :move_down]

  def index
    @categories = RetailCategory.ordered.to_a
    @counts = RetailProduct.group(:retail_category_id).count
  end

  def new
    @category = RetailCategory.new(position: (RetailCategory.maximum(:position) || 0) + 1, active: true)
  end

  def create
    @category = RetailCategory.new(category_params)
    if @category.save
      redirect_to admin_retail_catalog_categories_path, notice: "Categoría “#{@category.name}” creada."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @category.update(category_params)
      redirect_to admin_retail_catalog_categories_path, notice: "Categoría actualizada."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_active
    @category.update!(active: !@category.active?)
    redirect_to admin_retail_catalog_categories_path, notice: @category.active? ? "Categoría activada." : "Categoría desactivada: sus productos no se mostrarán en la tienda."
  end

  def destroy
    if @category.destroy
      redirect_to admin_retail_catalog_categories_path, notice: "Categoría eliminada."
    else
      redirect_to admin_retail_catalog_categories_path, alert: "No se puede eliminar “#{@category.name}”: tiene productos. Desactivala o mové sus productos a otra categoría."
    end
  end

  def move_up
    move(-1)
  end

  def move_down
    move(1)
  end

  private

  def set_category
    @category = RetailCategory.find(params[:id])
  end

  def category_params
    params.require(:retail_category).permit(:name, :position, :active)
  end

  # Reordena todas las categorías 1..n intercambiando la elegida con su vecina.
  def move(direction)
    RetailCategory.transaction do
      ordered = RetailCategory.lock.ordered.to_a
      index = ordered.index(@category)
      target = index + direction
      if target.between?(0, ordered.size - 1)
        ordered[index], ordered[target] = ordered[target], ordered[index]
        ordered.each_with_index { |c, i| c.update_columns(position: i + 1, updated_at: Time.current) if c.position != i + 1 }
      end
    end
    redirect_to admin_retail_catalog_categories_path
  end
end
