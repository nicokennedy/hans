# Zonas de envío a domicilio de la tienda minorista: alta, edición (nombre, cobertura orientativa,
# precio), activar/desactivar, orden y borrado solo si ningún pedido la usó (si no, se desactiva).
# Cambiar un precio no toca los pedidos ya creados: cada uno guardó su costo.
class Admin::RetailCatalog::DeliveryZonesController < Admin::RetailCatalog::BaseController
  before_action :set_zone, only: [:edit, :update, :destroy, :toggle_active, :move_up, :move_down]

  def new
    @zone = RetailDeliveryZone.new(position: (RetailDeliveryZone.maximum(:position) || 0) + 1, active: true)
  end

  def create
    @zone = RetailDeliveryZone.new(zone_params)
    if @zone.save
      redirect_to zones_path, notice: "Zona “#{@zone.name}” creada."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit; end

  def update
    if @zone.update(zone_params)
      redirect_to zones_path, notice: "Zona “#{@zone.name}” actualizada. Los pedidos ya creados conservan el costo que tenían."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_active
    @zone.update!(active: !@zone.active?)
    redirect_to zones_path, notice: @zone.active? ? "Zona “#{@zone.name}” activada." : "Zona “#{@zone.name}” desactivada: el cliente ya no puede elegirla."
  end

  def destroy
    if @zone.destroy
      redirect_to zones_path, notice: "Zona eliminada."
    else
      redirect_to zones_path, alert: "No se puede eliminar “#{@zone.name}”: hay pedidos con esa zona. Desactivala."
    end
  end

  def move_up
    move(-1)
  end

  def move_down
    move(1)
  end

  private

  def zones_path
    admin_retail_catalog_fulfillment_path(anchor: "zonas")
  end

  def set_zone
    @zone = RetailDeliveryZone.find(params[:id])
  end

  def zone_params
    params.require(:retail_delivery_zone).permit(:name, :coverage, :price, :position, :active)
  end

  def move(direction)
    RetailDeliveryZone.transaction do
      ordered = RetailDeliveryZone.lock.ordered.to_a
      index = ordered.index(@zone)
      target = index + direction
      if target.between?(0, ordered.size - 1)
        ordered[index], ordered[target] = ordered[target], ordered[index]
        ordered.each_with_index { |z, i| z.update_columns(position: i + 1, updated_at: Time.current) if z.position != i + 1 }
      end
    end
    redirect_to zones_path
  end
end
