# R4 (D9): foto del remito firmado cuando el pedido se entrega sin pago o con pago parcial.
# La subida va aparte de la entrega y del cobro: si falla, la parada queda "Falta la foto del
# remito" y el repartidor sigue. "El cliente no quiso firmar" es la excepción justificada.
class Reparto::PhotosController < Reparto::BaseController
  before_action :require_driver!
  before_action :set_stop

  def new
    @request_token = SecureRandom.uuid
  end

  def create
    result = DeliveryRoutes::Photos.new(@stop.delivery_route, current_user).attach(@stop, params[:foto], request_token: params[:request_token])
    if result.ok?
      redirect_to saved_reparto_stop_path(@stop), notice: "Listo: la foto del remito quedó guardada."
    else
      redirect_to saved_reparto_stop_path(@stop), alert: result.errors.join(" ")
    end
  end

  def no_signature
    result = DeliveryRoutes::Photos.new(@stop.delivery_route, current_user).no_signature(@stop)
    redirect_to saved_reparto_stop_path(@stop), result.ok? ? { notice: "Quedó anotado que el cliente no quiso firmar." } : { alert: result.errors.join(" ") }
  end

  private

  def set_stop
    @stop = find_driver_stop(params[:stop_id])
  end
end
