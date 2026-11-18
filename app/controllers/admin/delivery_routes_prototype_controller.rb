# R1: prototipo de la pantalla Repartos de administración (prototypes/repartos-admin.html).
# Datos de ejemplo; no lee ni escribe nada en la base. Solo admin.
class Admin::DeliveryRoutesPrototypeController < ApplicationController
  include RendersPrototype

  before_action :authenticate_user!
  before_action :require_admin!

  def show
    render_prototype Rails.root.join("prototypes/repartos-admin.html")
  end
end
