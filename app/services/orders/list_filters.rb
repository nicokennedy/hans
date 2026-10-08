module Orders
  # Filtros del listado Admin → Pedidos recibidos: cliente, fecha de entrega
  # (delivery_date, nunca created_at), estado de pago y página. Se leen SIEMPRE de
  # query params de la URL (y se vuelven a escribir en los links al pedido), así el
  # contexto sobrevive a pagos, ediciones y recargas sin depender del referer.
  #
  # Todo valor se valida: lo manipulado o inválido se ignora (nunca llega a SQL ni a
  # un redirect). Los params que se arrastran son solo estos cuatro, con valores
  # normalizados; jamás una URL.
  class ListFilters
    PAYMENT_STATUSES = %w[all pending partial paid].freeze
    PER_PAGE = 50

    attr_reader :customer_id, :delivery_date, :payment_status, :invalid_date, :total_count

    # params: ActionController::Parameters o Hash.
    # payment_fallback: filtro de pago previo (el que guarda la sesión) cuando la
    #   URL no trae uno. allow_payment: false para quien no ve datos de pagos.
    def initialize(params, payment_fallback: nil, allow_payment: true)
      @invalid_date = false
      @customer_id = parse_customer(params[:customer_id])
      @delivery_date = parse_date(params[:delivery_date])
      @payment_status = allow_payment ? parse_payment(params[:payment_status_filter].presence || payment_fallback) : "all"
      @requested_page = parse_page(params[:page])
    end

    def customer
      @customer ||= Customer.find_by(id: customer_id) if customer_id
    end

    def active?
      customer_id.present? || delivery_date.present? || payment_status != "all"
    end

    def apply(scope)
      scope = scope.where(customer_id: customer_id) if customer_id
      scope = scope.where(delivery_date: delivery_date) if delivery_date
      scope = scope.where(payment_status: payment_status) unless payment_status == "all"
      scope
    end

    # Aplica los filtros y pagina. Devuelve los pedidos de la página (acotada al
    # rango válido, así un ?page=999 manipulado no deja la pantalla vacía).
    def paginate(scope)
      @total_count = scope.count
      @page = [@requested_page, total_pages].min
      scope.offset((@page - 1) * PER_PAGE).limit(PER_PAGE)
    end

    def page
      @page || @requested_page
    end

    def total_pages
      [(total_count.to_f / PER_PAGE).ceil, 1].max
    end

    # Params canónicos para armar links (a la lista, al pedido, a export). Solo
    # incluye lo que no es el valor por defecto.
    def to_query(page: self.page)
      {
        customer_id: customer_id,
        delivery_date: delivery_date&.iso8601,
        payment_status_filter: (payment_status unless payment_status == "all"),
        page: (page if page.to_i > 1)
      }.compact
    end

    private

    def parse_customer(value)
      return nil unless value.is_a?(String) && value.match?(/\A\d{1,18}\z/)

      id = value.to_i
      Customer.exists?(id) ? id : nil
    end

    def parse_date(value)
      return nil if value.blank?
      return (@invalid_date = true) && nil unless value.is_a?(String)

      Date.iso8601(value)
    rescue ArgumentError
      @invalid_date = true
      nil
    end

    def parse_payment(value)
      PAYMENT_STATUSES.include?(value.to_s) ? value.to_s : "all"
    end

    def parse_page(value)
      return 1 unless value.is_a?(String) && value.match?(/\A\d{1,9}\z/)

      [value.to_i, 1].max
    end
  end
end
