# Contexto de navegación del listado de pedidos (filtros + página) para el detalle,
# la edición y los pagos. Viaja en query params (y en campos ocultos de los
# formularios), no en el referer ni en history.back(), así se conserva después de
# registrar un pago, guardar cambios o recargar. Solo se aceptan los cuatro params
# validados por Orders::ListFilters: nunca una URL, así no hay redirects abiertos.
#
# Si al pedido se entró desde Clientes (ficha o cuenta corriente), también arrastra ese
# contexto (Customers::NavigationContext) para que "Volver" regrese ahí y no a Pedidos.
module OrdersNavigationContext
  extend ActiveSupport::Concern

  included do
    helper_method :orders_context, :orders_list_context, :customers_context
  end

  private

  def orders_context
    @orders_context ||= orders_list_context.merge(customers_context.to_query)
  end

  # Solo los filtros del listado de Pedidos (para volver a la lista).
  def orders_list_context
    @orders_list_context ||= Orders::ListFilters.new(params, allow_payment: current_user&.admin?).to_query
  end

  def customers_context
    @customers_context ||= Customers::NavigationContext.new(params)
  end
end
