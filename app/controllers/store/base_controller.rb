# Base de la tienda pública minorista (/tienda). Separada del panel administrativo y del portal
# mayorista: layout propio, sin login y sin acceso a nada interno.
#
# Publicación: mientras la tienda está cerrada (RetailStoreSetting#published = false) el público ve
# "Próximamente" y solo los administradores la recorren en VISTA PREVIA: ven el catálogo, el carrito
# y el checkout reales, pero al finalizar no se registra ningún pedido (ver Store::CheckoutsController).
# Protección CSRF: la de Rails (ActionController::Base), con el token en cada formulario.
class Store::BaseController < ApplicationController
  layout "store"

  before_action :set_store_setting
  before_action :store_headers
  before_action :require_open_store

  helper_method :store_cart, :store_preview?, :store_setting

  private

  def set_store_setting
    @store_setting = RetailStoreSetting.current
  end

  def store_setting
    @store_setting
  end

  # Tienda cerrada recorrida por un administrador.
  def store_preview?
    !@store_setting.published? && current_user&.admin?
  end

  def require_open_store
    return if @store_setting.published? || store_preview?

    # 200 con noindex (cabecera y meta): una página "Próximamente", no un error del servidor.
    render "store/closed"
  end

  def store_cart
    @store_cart ||= Retail::StoreCart.new(session)
  end

  def throttle!(action)
    return true if Retail::StoreThrottle.allow?(action, request.remote_ip)

    render "store/throttled", status: :too_many_requests
    false
  end

  def store_headers
    # Mientras está cerrada (o en vista previa), que ningún buscador la indexe.
    response.set_header("X-Robots-Tag", "noindex, nofollow") unless @store_setting.published?
  end

  # Ruta pública de un producto: /tienda/productos/12-box-de-cookies
  def store_product_slug(product)
    "#{product.id}-#{product.name.parameterize}"
  end
  helper_method :store_product_slug
end
