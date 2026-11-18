# R1: prototipo navegable del portal del repartidor (prototypes/reparto.html), MODO
# DEMOSTRACIÓN con datos ficticios: no lee ni escribe nada en la base. Lo usan el repartidor
# y el admin (para probar la misma experiencia del celular sin entrar como repartidor).
class Reparto::PrototypeController < Reparto::BaseController
  include RendersPrototype

  def show
    exit_url = current_user.admin? ? admin_delivery_routes_demo_path : reparto_root_path
    render_prototype Rails.root.join("prototypes/reparto.html"), exit_url: exit_url
  end
end
