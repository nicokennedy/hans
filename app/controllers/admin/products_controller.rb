require "fileutils"

class Admin::ProductsController < ApplicationController
  before_action :authenticate_user!
  SORT_OPTIONS = {
    "name" => "products.name", "category" => "categories.name",
    "price" => "products.price_cents", "cost" => "products.cost_cents"
  }.freeze
  SORT_DIRECTIONS = %w[asc desc].freeze

  before_action :require_admin!
  before_action :set_product, only: [:edit, :update, :destroy]

  def index
    @categories = Category.ordered
    @products = filtered_products
  end

  def new
    @product = Product.new(active: true)
  end

  def create
    @product = Product.new(product_params)

    if @product.save
      redirect_to admin_products_path, notice: "Producto creado correctamente."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @product.update(product_params)
      redirect_to admin_products_path(product_index_params), notice: "Producto actualizado correctamente."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @product.destroy
    redirect_to admin_products_path(product_index_params), notice: "Producto eliminado correctamente."
  end

  def import
  end

  def preview_import
    if params[:file].blank?
      redirect_to import_admin_products_path, alert: "Seleccioná un archivo CSV."
      return
    end

    unless csv_upload?(params[:file])
      redirect_to import_admin_products_path, alert: "El archivo debe ser CSV."
      return
    end

    token = store_import_file(params[:file])
    @import_token = token
    @result = Products::AdminCsvImporter.new(path: import_file_path(token)).call

    render :import_preview
  rescue => e
    redirect_to import_admin_products_path, alert: "No se pudo leer el archivo: #{e.message}"
  end

  def confirm_import
    token = params[:import_token].to_s

    unless token.match?(/\A[0-9a-f]{32}\z/)
      redirect_to import_admin_products_path, alert: "La previsualización expiró. Subí el archivo nuevamente."
      return
    end

    path = import_file_path(token)

    unless path.exist?
      redirect_to import_admin_products_path, alert: "La previsualización expiró. Subí el archivo nuevamente."
      return
    end

    @result = Products::AdminCsvImporter.new(path: path, apply: true).call
    path.delete if path.exist?

    redirect_to admin_products_path, notice: import_summary(@result)
  rescue => e
    redirect_to import_admin_products_path, alert: "No se pudo importar el archivo: #{e.message}"
  end

  private

  def filtered_products
    products = Product.includes(:category)
    if params[:q].present?
      query = Product.sanitize_sql_like(params[:q].strip)
      products = products.where("products.name ILIKE ?", "%#{query}%")
    end
    products = products.where(category_id: params[:category_id]) if params[:category_id].present?
    products = products.where(active: params[:status] == "active") if %w[active inactive].include?(params[:status])
    sort_column = SORT_OPTIONS[params[:sort]]
    sort_direction = params[:direction] if SORT_DIRECTIONS.include?(params[:direction])
    if sort_column.present? && sort_direction.present?
      products.left_joins(:category).reorder(Arel.sql("#{sort_column} #{sort_direction}"))
    else
      products.ordered
    end
  end

  def product_index_params
    params.permit(:q, :category_id, :status, :sort, :direction)
  end
  def set_product
    @product = Product.find(params[:id])
  end

  def product_params
    params.require(:product).permit(
      :name,
      :description,
      :price_amount,
    	:cost_amount,
      :category_id,
      :position,
      :active
    )
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end

  def store_import_file(upload)
    token = SecureRandom.hex(16)
    FileUtils.mkdir_p(imports_directory)
    File.binwrite(import_file_path(token), upload.read)
    token
  end

  def csv_upload?(upload)
    File.extname(upload.original_filename.to_s).downcase == ".csv"
  end

  def imports_directory
    Rails.root.join("tmp/product_imports")
  end

  def import_file_path(token)
    imports_directory.join("#{token}.csv")
  end

  def import_summary(result)
    "Importación aplicada. Nuevos: #{result.new_rows.count}. Actualizados: #{result.updated_rows.count}. Sin cambios: #{result.unchanged_rows.count}. Errores: #{result.error_rows.count}."
  end
end
