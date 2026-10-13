# Contexto de navegación del listado de pedidos minoristas (filtros + página): viaja en query
# params validados por Retail::ListFilters (nunca una URL), así se conserva al entrar a un
# pedido, editarlo, registrar un pago o volver al listado.
module RetailNavigationContext
  extend ActiveSupport::Concern

  included do
    helper_method :retail_context
  end

  private

  def retail_context
    @retail_context ||= Retail::ListFilters.new(params).to_query
  end
end
