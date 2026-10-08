module Stock
  # Historial de movimientos de UN StockItem para la pantalla "Ver historial".
  # Es SOLO LECTURA: no escribe nada, no concilia pedidos y no recalcula saldos.
  # Reutiliza el ledger existente (StockMovement): cada fila ya guarda la
  # cantidad con signo, el stock resultante justo después del movimiento
  # (resulting_quantity, escrito bajo lock al registrarlo), el pedido, el usuario
  # y la nota. Acá solo se filtra, pagina y se arma lo necesario para mostrarlo.
  #
  # Cómo representa HANS cada cosa (no se inventa nada):
  #  - production  (+)   : producción registrada a mano.
  #  - dispatch    (-)   : venta; la materializa Stock::DispatchReconciler a partir
  #                        de la fecha de entrega (corte 13:00), por pedido.
  #  - dispatch    (+)   : corrección del reconciliador: el pedido se canceló, se
  #                        redujo o se pasó a una fecha futura DESPUÉS de haberse
  #                        descontado. HANS no guarda el motivo; se informa el
  #                        estado actual del pedido (cancelado o no).
  #  - adjustment  (+/-) : conteo físico / corrección manual (con usuario y nota).
  # Las modificaciones/cancelaciones hechas ANTES de que se descuente el pedido no
  # generan movimiento alguno (es solo demanda comprometida, no stock físico).
  class MovementHistory
    FILTERS = %w[all production sale adjustment correction].freeze
    PER_PAGE = 25
    # Un pedido con varios productos del mismo stock (ej. un pool) genera varias
    # salidas casi simultáneas al descontarse. Una salida posterior en más de este
    # margen a la primera del pedido es, en cambio, un ajuste por modificación.
    SAME_BATCH_SECONDS = 60

    Entry = Struct.new(
      :movement, :kind, :order, :user, :products, :order_net, :follow_up, :correction_reason,
      keyword_init: true
    ) do
      def increase?
        movement.quantity.positive?
      end
    end

    attr_reader :stock_item, :filter, :from, :to, :page, :invalid_dates

    def initialize(stock_item, filter: nil, from: nil, to: nil, page: nil, per_page: PER_PAGE)
      @stock_item = stock_item
      @filter = FILTERS.include?(filter.to_s) ? filter.to_s : "all"
      @invalid_dates = false
      @from = parse_date(from)
      @to = parse_date(to)
      @per_page = per_page
      @requested_page = [page.to_i, 1].max
    end

    def total_count
      @total_count ||= scope.count
    end

    def total_pages
      [(total_count.to_f / @per_page).ceil, 1].max
    end

    def page
      [@requested_page, total_pages].min
    end

    def previous_page
      page > 1 ? page - 1 : nil
    end

    def next_page
      page < total_pages ? page + 1 : nil
    end

    def filtered?
      filter != "all" || from.present? || to.present?
    end

    def entries
      @entries ||= build_entries(page_movements)
    end

    # Cantidad de movimientos de cada tipo del ítem completo (sin filtros),
    # para mostrarla en los botones de filtro.
    def counts
      @counts ||= {
        "all" => base_scope.count,
        "production" => apply_kind(base_scope, "production").count,
        "sale" => apply_kind(base_scope, "sale").count,
        "adjustment" => apply_kind(base_scope, "adjustment").count,
        "correction" => apply_kind(base_scope, "correction").count
      }
    end

    def self.kind_of(movement)
      case movement.movement_type
      when "production" then "production"
      when "adjustment" then "adjustment"
      else movement.quantity.negative? ? "sale" : "correction"
      end
    end

    private

    def base_scope
      stock_item.stock_movements
    end

    def scope
      @scope ||= begin
        relation = apply_kind(base_scope, filter)
        relation = relation.where("stock_movements.created_at >= ?", from.in_time_zone.beginning_of_day) if from
        relation = relation.where("stock_movements.created_at <= ?", to.in_time_zone.end_of_day) if to
        relation
      end
    end

    def apply_kind(relation, kind)
      case kind
      when "production" then relation.where(movement_type: "production")
      when "adjustment" then relation.where(movement_type: "adjustment")
      when "sale" then relation.where(movement_type: "dispatch").where("stock_movements.quantity < 0")
      when "correction" then relation.where(movement_type: "dispatch").where("stock_movements.quantity > 0")
      else relation
      end
    end

    # Más reciente primero; el id desempata los movimientos creados en el mismo
    # instante (la conciliación escribe varios juntos).
    def page_movements
      scope.includes(:user, order: :customer)
           .order(created_at: :desc, id: :desc)
           .offset((page - 1) * @per_page)
           .limit(@per_page)
           .to_a
    end

    def build_entries(movements)
      order_ids = movements.filter_map(&:order_id).uniq
      nets = order_ids.any? ? StockMovement.dispatch.where(stock_item: stock_item, order_id: order_ids).group(:order_id).sum(:quantity) : {}
      first_ids = order_ids.any? ? StockMovement.dispatch.where(stock_item: stock_item, order_id: order_ids).group(:order_id).minimum(:id) : {}
      first_times = order_ids.any? ? StockMovement.dispatch.where(stock_item: stock_item, order_id: order_ids).group(:order_id).minimum(:created_at) : {}
      items_by_order = order_ids.any? ? OrderItem.where(order_id: order_ids).includes(:product).group_by(&:order_id) : {}

      movements.map do |movement|
        kind = self.class.kind_of(movement)
        order = movement.order

        Entry.new(
          movement: movement,
          kind: kind,
          order: order,
          user: movement.user,
          order_net: order ? nets[order.id] : nil,
          follow_up: order.present? && kind == "sale" && movement.created_at - first_times[order.id] > SAME_BATCH_SECONDS,
          correction_reason: kind == "correction" && order ? (order.canceled? ? :canceled : :modified) : nil,
          products: order && kind == "sale" && first_ids[order.id] == movement.id ? order_products(order, items_by_order[order.id], nets[order.id]) : []
        )
      end
    end

    # Productos del pedido que hoy descuentan de este stock (directo o por un pool
    # compartido, según ProductConsumption), listados una sola vez: en la primera
    # salida del pedido sobre este stock (el ledger no guarda qué producto originó
    # cada movimiento, solo el pedido). Solo se muestran si el total calculado
    # coincide con lo realmente descontado al pedido: si la configuración de pools
    # cambió desde entonces, es preferible omitir el detalle antes que mostrar uno
    # que no cierre.
    def order_products(order, items, net)
      return [] if order.canceled? || items.blank? || net.nil? || !net.negative?

      rows = items.filter_map do |item|
        per_unit = consumption_for(item.product)[stock_item]
        next unless per_unit&.positive?

        [item.product_name_snapshot.presence || item.product.name, item.quantity, item.quantity * per_unit]
      end

      rows.sum { |_, _, amount| amount } == -net ? rows : []
    end

    def consumption_for(product)
      @consumption ||= {}
      @consumption[product.id] ||= Stock::ProductConsumption.call(product)
    end

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      @invalid_dates = true
      nil
    end
  end
end
