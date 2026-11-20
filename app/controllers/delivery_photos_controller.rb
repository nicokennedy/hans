# R4: muestra la foto de un remito firmado. Nunca hay enlace público: pasa siempre por acá y
# solo la ven administración y el repartidor de ese recorrido.
class DeliveryPhotosController < ApplicationController
  before_action :authenticate_user!

  def show
    photo = DeliveryPhoto.includes(:delivery_route, image_attachment: :blob).find_by(id: params[:id])
    allowed = photo && (current_user.admin? || (current_user.driver? && photo.delivery_route.driver_id == current_user.id))
    return head(:not_found) unless allowed && photo.image.attached?

    response.headers["Cache-Control"] = "private, no-store"
    send_data photo.image.download, type: photo.image.content_type, disposition: "inline", filename: photo.image.filename.to_s
  end
end
