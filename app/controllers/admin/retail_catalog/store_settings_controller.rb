# Tienda Minorista → Tienda online: publicación de la tienda pública, WhatsApp de HANS y datos para
# transferencia. Solo administradores (BaseController). Publicar o cerrar es una acción explícita
# que queda registrada (quién y cuándo).
class Admin::RetailCatalog::StoreSettingsController < Admin::RetailCatalog::BaseController
  before_action :set_setting

  def show
    load_readiness
  end

  def update
    @setting.assign_attributes(params.permit(:whatsapp_number, :bank_transfer_details).to_h)
    @setting.updated_by = current_user
    if @setting.save
      redirect_to admin_retail_catalog_store_settings_path, notice: "Datos de la tienda guardados."
    else
      @errors = @setting.errors.full_messages
      load_readiness
      render :show, status: :unprocessable_entity
    end
  end

  def publish
    unless params[:confirm] == "1"
      return redirect_to(admin_retail_catalog_store_settings_path, alert: "Para publicar la tienda marcá la casilla de confirmación.")
    end

    @setting.update!(published: true, published_at: Time.current, updated_by: current_user)
    Rails.logger.info("[tienda] publicada por el usuario #{current_user.id}")
    redirect_to admin_retail_catalog_store_settings_path, notice: "La tienda está publicada: cualquier persona puede verla y hacer pedidos."
  end

  def unpublish
    @setting.update!(published: false, updated_by: current_user)
    Rails.logger.info("[tienda] cerrada por el usuario #{current_user.id}")
    redirect_to admin_retail_catalog_store_settings_path, notice: "La tienda está cerrada al público. Los administradores la siguen viendo en vista previa."
  end

  private

  def set_setting
    @setting = RetailStoreSetting.current
  end

  def load_readiness
    @published_products = RetailProduct.for_store.count
    @active_products = RetailProduct.active.count
    @pickup_details = RetailFulfillmentSetting.current.pickup_point_details
    @active_zones = RetailDeliveryZone.active.count
    @awaiting_orders = RetailOrder.source_store.awaiting_review.count
  end
end
