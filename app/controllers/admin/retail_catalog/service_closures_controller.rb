# Fechas puntuales sin retiro, sin envío o sin ninguno de los dos en la tienda minorista. No
# cambian los días habituales ni el calendario mayorista (BlockedDate).
class Admin::RetailCatalog::ServiceClosuresController < Admin::RetailCatalog::BaseController
  def create
    closure = RetailServiceClosure.new(params.require(:retail_service_closure).permit(:date, :service, :reason))
    closure.created_by = current_user
    if closure.save
      redirect_to closures_path, notice: "#{closure.date.strftime('%d/%m/%Y')} bloqueada (#{closure.service_label.downcase_first})."
    else
      redirect_to closures_path, alert: closure.errors.full_messages.to_sentence
    end
  end

  def destroy
    closure = RetailServiceClosure.find(params[:id])
    closure.destroy!
    redirect_to closures_path, notice: "#{closure.date.strftime('%d/%m/%Y')} vuelve a estar disponible (#{closure.service_label.downcase_first})."
  end

  private

  def closures_path
    admin_retail_catalog_fulfillment_path(anchor: "fechas-sin-servicio")
  end
end
