# R1: prototipo navegable del portal del repartidor (prototypes/reparto.html), con datos de
# ejemplo: no lee ni escribe nada en la base.
class Reparto::PrototypeController < Reparto::BaseController
  include RendersPrototype

  def show
    render_prototype Rails.root.join("prototypes/reparto.html")
  end
end
