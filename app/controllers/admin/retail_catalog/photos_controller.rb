# Fotos de un producto minorista: subir varias, reemplazar, elegir la principal, ordenar y
# borrar. Si el almacenamiento (Cloudflare R2) no está habilitado, no se aceptan subidas.
class Admin::RetailCatalog::PhotosController < Admin::RetailCatalog::BaseController
  before_action :set_product
  before_action :set_photo, except: [:create]

  def create
    result = RetailCatalog::PhotoUpload.add(product: @product, files: params[:images])
    flash[:notice] = "#{result.saved.size} #{result.saved.size == 1 ? 'foto agregada' : 'fotos agregadas'}." if result.saved.any?
    flash[:alert] = result.errors.join(" ") if result.errors.any?
    redirect_to photos_path
  end

  def update
    result = RetailCatalog::PhotoUpload.replace(photo: @photo, file: params[:image])
    result.ok? ? flash[:notice] = "Foto reemplazada." : flash[:alert] = result.errors.join(" ")
    redirect_to photos_path
  end

  def make_primary
    RetailCatalog::PhotoArrangement.make_primary(@photo)
    redirect_to photos_path, notice: "Foto principal actualizada."
  end

  def move_up
    error = RetailCatalog::PhotoArrangement.move(@photo, -1)
    redirect_to photos_path, alert: error
  end

  def move_down
    error = RetailCatalog::PhotoArrangement.move(@photo, 1)
    redirect_to photos_path, alert: error
  end

  def destroy
    error = RetailCatalog::PhotoArrangement.destroy(@photo, confirm_last: params[:confirm_last] == "1")
    error ? redirect_to(photos_path, alert: error) : redirect_to(photos_path, notice: "Foto eliminada.")
  end

  private

  def set_product
    @product = RetailProduct.find(params[:product_id])
  end

  def set_photo
    @photo = @product.photos.find(params[:id])
  end

  def photos_path
    admin_retail_catalog_product_path(@product, anchor: "fotos")
  end
end
