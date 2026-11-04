# Tienda Minorista → catálogo (productos, categorías y fotos). Solo administradores: los permisos
# se validan acá, en el servidor (no alcanza con ocultar botones). Clientes mayoristas y
# producción quedan afuera de todas las acciones.
class Admin::RetailCatalog::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!
end
