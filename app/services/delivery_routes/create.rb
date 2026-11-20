module DeliveryRoutes
  # Arma un recorrido de un repartidor (obligatorio y activo, R3) para una fecha con los pedidos
  # mayoristas elegidos (sin cancelados y que no estén en otra parada vigente). Un repartidor
  # puede tener varios recorridos el mismo día (Reparto 1, 2...), cada uno independiente.
  # creation_token (uno por formulario) evita duplicar el recorrido por doble clic o reintento:
  # si ya existe un recorrido con ese token, se devuelve ese mismo. Ordena las paradas como el último recorrido en el que
  # aparecía cada cliente; los clientes nuevos van al final, por nombre. No toca los pedidos.
  class Create
    def self.call(**args)
      new(**args).call
    end

    def initialize(date:, order_ids:, user:, driver: nil, creation_token: nil)
      @date = date
      @order_ids = Array(order_ids).map(&:to_i).uniq
      @user = user
      @driver = driver
      @token = creation_token.to_s.strip.presence&.first(64)
    end

    def call
      return Result.new(errors: ["Elegí una fecha válida."]) unless @date.is_a?(Date)
      return Result.new(errors: ["Elegí el repartidor responsable del recorrido."]) unless @driver
      return Result.new(errors: ["#{@driver.display_name} no es un repartidor activo."]) unless @driver.driver? && @driver.active?
      return Result.new(route: already_created, errors: [], already: true) if already_created

      route = nil
      errors = []
      DeliveryRoute.transaction do
        orders = Order.for_delivery_date(@date).where(id: @order_ids).includes(:customer).to_a
        missing = @order_ids - orders.map(&:id)
        errors << "Algunos pedidos elegidos no son de esta fecha o están cancelados (#{missing.size})." if missing.any?
        taken = DeliveryStop.active.where(order_id: @order_ids).includes(:delivery_route, order: :customer).to_a
        taken.each { |stop| errors << "#{stop.display_name} (#{stop.order.number}) ya está en #{stop.delivery_route.title} del #{I18n.l(stop.delivery_route.date, format: '%d/%m')}." }
        raise ActiveRecord::Rollback if errors.any?

        route = DeliveryRoute.create!(date: @date, driver: @driver, created_by: @user, creation_token: @token)
        sorted(orders).each_with_index do |order, index|
          route.stops.create!(kind: "order", order: order, customer: order.customer, position: index + 1)
        end
        Events.record(route, @user, "route_created",
                      summary: "Armó el #{route.label} del #{I18n.l(@date, format: '%d/%m/%Y')} de #{@driver.display_name} con #{orders.size} pedido(s).",
                      order_ids: orders.map(&:id))
      end

      Result.new(route: route, errors: errors)
    rescue ActiveRecord::RecordNotUnique
      # Dos envíos del mismo formulario a la vez: el segundo choca con el token del primero.
      @already_created = nil
      return Result.new(route: already_created, errors: [], already: true) if already_created

      Result.new(errors: ["Alguno de los pedidos elegidos ya está en otro recorrido (otro usuario lo agregó al mismo tiempo). Revisá y volvé a intentar."])
    end

    private

    def already_created
      return unless @token

      @already_created ||= DeliveryRoute.find_by(creation_token: @token)
    end

    def sorted(orders)
      previous = DeliveryRoutes.previous_positions(orders.map(&:customer_id), before: @date)
      orders.sort_by do |order|
        pos = previous[order.customer_id]
        [pos ? 0 : 1, pos || 0, Customer.normalize_search(order.customer.name), order.id]
      end
    end
  end

  # Posición de cada cliente en su último recorrido anterior a la fecha (para sugerir el orden).
  def self.previous_positions(customer_ids, before:)
    DeliveryStop.active.joins(:delivery_route)
                .where(customer_id: customer_ids).where("delivery_routes.date < ?", before)
                .order("delivery_routes.date DESC, delivery_stops.id DESC")
                .pluck(:customer_id, :position)
                .each_with_object({}) { |(customer_id, position), memo| memo[customer_id] ||= position }
  end
end
