# Portal del repartidor (/reparto). Pensado para el iPhone corporativo y para una persona con
# poca experiencia con sistemas: layout propio, sin menú lateral ni pantallas de admin.
# Entran el repartidor y el admin (vista previa). Ver docs/REPARTOS_Y_RENDICIONES.md.
class Reparto::BaseController < ApplicationController
  layout "reparto"

  before_action :authenticate_user!
  before_action :require_driver_or_admin!
end
