# Paradas de un recorrido (R2): agregar pedidos o paradas manuales, reordenar, quitar, volver
# a agregar y editar. Solo admin. Todo pasa por DeliveryRoutes::Editor (transacción + historial).
class Admin::DeliveryRouteStopsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_route
  before_action :set_stop, only: [:update, :move, :remove, :restore, :transfer, :ungroup, :receipt]

  def add_orders
    respond_with editor.add_orders(params[:order_ids]), "Pedidos agregados al final del recorrido."
  end

  def group
    respond_with editor.group(params[:stop_ids]), "Pedidos unificados en una parada."
  end

  def ungroup
    respond_with editor.ungroup(@stop), "Pedidos desagrupados."
  end

  def receipt
    return head :not_found unless @stop.order? && @stop.group_leader_id.nil?

    render "reparto/photos/receipt", layout: "reparto"
  end

  def create
    attrs = params.require(:stop).permit(:kind, :title, :address, :notes)
    respond_with editor.add_manual(kind: attrs[:kind], title: attrs[:title], address: attrs[:address], notes: attrs[:notes]),
                 "Parada agregada al final del recorrido."
  end

  def update
    attrs = params.require(:stop).permit(:title, :address, :notes)
    respond_with editor.update_manual(@stop, title: attrs[:title], address: attrs[:address], notes: attrs[:notes]), "Parada actualizada."
  end

  def move
    respond_with editor.move(@stop, params[:direction]), nil, anchor: "parada-#{@stop.id}"
  end

  def remove
    respond_with editor.remove(@stop, removal_kind: params[:removal_kind], reason: params[:removal_reason]),
                 "#{@stop.display_name} salió del recorrido. El pedido no se modificó."
  end

  def restore
    respond_with editor.restore(@stop), "#{@stop.display_name} volvió al final del recorrido."
  end

  def transfer
    target = DeliveryRoute.find_by(id: params[:target_route_id])
    respond_with editor.transfer(@stop, target), "#{@stop.display_name} pasó a #{target&.title}."
  end

  private

  def editor
    DeliveryRoutes::Editor.new(@route, current_user)
  end

  def set_route
    @route = DeliveryRoute.find(params[:delivery_route_id])
  end

  def set_stop
    @stop = @route.stops.find(params[:id])
  end

  def respond_with(result, notice, anchor: nil)
    flash_options = result.ok? ? (notice ? { notice: notice } : {}) : { alert: result.errors.join(" ") }
    redirect_to admin_delivery_route_path(@route, anchor: anchor), flash_options
  end
end
