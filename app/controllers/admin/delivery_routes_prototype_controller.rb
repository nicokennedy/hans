# Repartos en administración — por ahora solo MODO DEMOSTRACIÓN (R1): una portada y el
# prototipo de administración (prototypes/repartos-admin.html). El prototipo del repartidor
# se abre en /reparto/prototipo, que el admin también puede usar. Datos ficticios: nada de
# esto lee ni escribe la base. Solo admin.
class Admin::DeliveryRoutesPrototypeController < ApplicationController
  include RendersPrototype

  before_action :authenticate_user!
  before_action :require_admin!

  def index
  end

  def show
    render_prototype Rails.root.join("prototypes/repartos-admin.html"), exit_url: admin_delivery_routes_demo_path
  end
end
