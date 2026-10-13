module Retail
  # Filtros del listado de pedidos minoristas: fecha de entrega (un día o un rango), nombre del
  # comprador, tipo de entrega, estado operativo, estado de pago y página. Viajan siempre en
  # query params (y se reescriben en los links al pedido) para conservarlos al entrar y volver.
  # Todo valor se valida: lo manipulado o inválido se ignora; nunca se arrastra una URL.
  class ListFilters
    PER_PAGE = 50

    attr_reader :date_from, :date_to, :buyer, :delivery_kind, :status, :payment_status, :invalid_date, :total_count

    def initialize(params)
      @invalid_date = false
      @date_from = parse_date(params[:date_from])
      @date_to = parse_date(params[:date_to])
      @buyer = params[:buyer].is_a?(String) ? params[:buyer].squish.first(100).presence : nil
      @delivery_kind = pick(params[:kind], RetailOrder.delivery_kinds.keys)
      @status = pick(params[:status], RetailOrder.statuses.keys)
      @payment_status = pick(params[:payment_status], RetailOrder.payment_statuses.keys)
      @requested_page = parse_page(params[:page])
    end

    def active?
      [date_from, date_to, buyer, delivery_kind, status, payment_status].any?(&:present?)
    end

    def apply(scope)
      if date_from && date_to
        scope = scope.where(delivery_date: [date_from, date_to].min..[date_from, date_to].max)
      elsif date_from
        scope = scope.where(delivery_date: date_from)
      elsif date_to
        scope = scope.where("retail_orders.delivery_date <= ?", date_to)
      end
      scope = scope.where("retail_orders.buyer_name ILIKE ?", "%#{RetailOrder.sanitize_sql_like(buyer)}%") if buyer
      scope = scope.where(delivery_kind: delivery_kind) if delivery_kind
      scope = scope.where(status: status) if status
      scope = scope.where(payment_status: payment_status) if payment_status
      scope
    end

    # Más cercana a hoy primero: hoy y próximos días en orden ascendente, después los pasados
    # del más reciente al más antiguo.
    def self.order_by_nearest(scope, today: Date.current)
      quoted = RetailOrder.connection.quote(today)
      scope.order(Arel.sql("(retail_orders.delivery_date < #{quoted}) ASC"))
           .order(Arel.sql("CASE WHEN retail_orders.delivery_date >= #{quoted} THEN retail_orders.delivery_date END ASC"))
           .order(Arel.sql("CASE WHEN retail_orders.delivery_date < #{quoted} THEN retail_orders.delivery_date END DESC"))
           .order(:id)
    end

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

    def to_query(page: self.page)
      {
        date_from: date_from&.iso8601,
        date_to: date_to&.iso8601,
        buyer: buyer,
        kind: delivery_kind,
        status: status,
        payment_status: payment_status,
        page: (page if page.to_i > 1)
      }.compact
    end

    private

    def pick(value, allowed)
      value.is_a?(String) && allowed.include?(value) ? value : nil
    end

    def parse_date(value)
      return nil if value.blank?
      return (@invalid_date = true) && nil unless value.is_a?(String)

      Date.iso8601(value)
    rescue ArgumentError
      @invalid_date = true
      nil
    end

    def parse_page(value)
      return 1 unless value.is_a?(String) && value.match?(/\A\d{1,9}\z/)

      [value.to_i, 1].max
    end
  end
end
