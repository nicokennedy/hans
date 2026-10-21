# Contexto de navegación de Clientes (búsqueda, origen y filtros de la cuenta corriente) para
# las pantallas de cliente, cuenta corriente y sus pagos. Ver Customers::NavigationContext.
module CustomersNavigationContext
  extend ActiveSupport::Concern

  included do
    helper_method :customers_context
  end

  private

  def customers_context
    @customers_context ||= Customers::NavigationContext.new(params)
  end
end
