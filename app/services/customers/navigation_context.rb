module Customers
  # Contexto de navegación del módulo Clientes, el equivalente de Orders::ListFilters para
  # Pedidos: viaja en query params (y en campos ocultos de los formularios) para que, al
  # entrar a la cuenta corriente, a un pago o a un pedido desde Clientes, "Volver" regrese a
  # Clientes con la misma búsqueda y no a Pedidos.
  #
  #   q         búsqueda del listado de clientes
  #   via       "customer" si a la cuenta corriente se entró desde la ficha del cliente
  #   back_to   "customer" | "account": a un pedido se entró desde la ficha o desde la cuenta
  #   filter, from, to  filtros de la cuenta corriente (mismos nombres que esa pantalla)
  #
  # Todo valor se valida y lo inválido se ignora. Nunca se acepta una URL: el destino se arma
  # siempre con el cliente del propio registro, así no hay redirects abiertos.
  class NavigationContext
    VIAS = %w[customer].freeze
    BACK_TOS = %w[customer account].freeze

    attr_reader :q, :via, :back_to, :filter, :from, :to

    def initialize(params)
      @q = params[:q].to_s.squish.first(Customer::SEARCH_MAX_LENGTH).presence if params[:q].is_a?(String)
      @via = params[:via] if VIAS.include?(params[:via])
      @back_to = params[:back_to] if BACK_TOS.include?(params[:back_to])
      @filter = params[:filter] if (CustomerAccounts::Summary::FILTERS - ["all"]).include?(params[:filter])
      @from = iso_date(params[:from])
      @to = iso_date(params[:to])
    end

    # Para volver al listado de clientes o a la ficha.
    def list_query
      { q: q }.compact
    end

    # Para volver a la cuenta corriente (y para sus links/formularios internos).
    def account_query
      { q: q, via: via, filter: filter, from: from, to: to }.compact
    end

    # Para entrar a un pedido desde la ficha o desde la cuenta corriente.
    def order_query(from_screen)
      (from_screen == "account" ? account_query : list_query).merge(back_to: from_screen)
    end

    # Todo lo presente, para arrastrarlo por las pantallas del pedido.
    def to_query
      account_query.merge(back_to: back_to).compact
    end

    private

    def iso_date(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{4}-\d{2}-\d{2}\z/)

      Date.iso8601(value).iso8601
    rescue ArgumentError
      nil
    end
  end
end
