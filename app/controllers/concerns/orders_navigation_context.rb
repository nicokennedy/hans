# Contexto de navegación del listado de pedidos (filtros + página) para el detalle,
# la edición y los pagos. Viaja en query params (y en campos ocultos de los
# formularios), no en el referer ni en history.back(), así se conserva después de
# registrar un pago, guardar cambios o recargar. Solo se aceptan los cuatro params
# validados por Orders::ListFilters: nunca una URL, así no hay redirects abiertos.
module OrdersNavigationContext
  extend ActiveSupport::Concern

  included do
    helper_method :orders_context
  end

  private

  def orders_context
    @orders_context ||= Orders::ListFilters.new(params, allow_payment: current_user&.admin?).to_query
  end
end
