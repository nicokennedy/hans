module DeliveryRoutes
  # Cobros en efectivo de un recorrido (R4). NO tiene lógica financiera propia: cada cobro es un
  # pago de cuenta corriente registrado con CustomerAccounts::RegisterPayment (efectivo
  # contraentrega, fecha de hoy, usuario = quien lo registra), que ya bloquea cliente y pedidos,
  # valida que no se aplique más que el saldo de cada pedido y deja el sobrante como saldo a
  # favor. Acá solo se agrega el vínculo con el recorrido (DeliveryCollection), en la MISMA
  # transacción, con el recorrido bloqueado (así no se cruza con el envío de la rendición).
  #
  # Idempotente: el request_token del formulario identifica el cobro; si llega dos veces (doble
  # toque, reintento) se devuelve el mismo cobro. Corregir = anular (VoidPayment, con motivo) y
  # registrar el correcto; nunca se borra nada. No toca stock ni pedidos de otros clientes.
  class Collections
    PAYMENT_METHOD = "cash_on_delivery".freeze

    Result = Struct.new(:collection, :errors, :already, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    # Pedidos con saldo del cliente de la parada (D5: solo ese cliente), el de la parada primero.
    def self.pending_orders_for(stop)
      orders = CustomerAccounts::Distribution.pending_orders(stop.customer).to_a
      own = orders.find { |order| order.id == stop.order_id }
      own ? [own] + (orders - [own]) : orders
    end

    def initialize(route, user)
      @route = route
      @user = user
    end

    # allocations: { order_id => cents } (pedidos del cliente de la parada). Lo no aplicado queda
    # como saldo a favor. unidentified: todo a saldo a favor, marcado "A identificar".
    def record(stop:, amount_cents:, allocations: {}, unidentified: false, request_token:, report: nil)
      token = request_token.to_s.strip
      return failure("Falta el identificador del formulario. Volvé a intentar.") if token.blank?

      run(token) do
        stop = active_order_stop(stop)
        next ["Esta parada no es un pedido."] unless stop

        register(stop, amount_cents, allocations, unidentified, token, report: report)
      end
    end

    # Corrige un cobro con motivo: anula el anterior (y su pago de cuenta corriente) y, si el
    # importe nuevo es mayor a cero, registra el correcto. Importe nuevo 0 = "no me pagaron".
    # allocations nil: se reparte el importe nuevo entre los mismos pedidos del cobro original
    # (en ese orden; lo que sobra, saldo a favor). Administración puede indicar otra distribución.
    def correct(collection, amount_cents:, reason:, request_token:, allocations: nil, unidentified: nil)
      token = request_token.to_s.strip
      reason = reason.to_s.squish
      return failure("Falta el identificador del formulario. Volvé a intentar.") if token.blank?

      run(token) do
        old = DeliveryCollection.lock.find(collection.id)
        next ["Ese cobro no es de este recorrido."] unless old.delivery_route_id == @route.id
        next ["Ese cobro ya fue corregido. Revisá la lista de cobros."] if old.voided?
        next ["Escribí el motivo de la corrección."] if reason.blank?
        next ["El importe no es válido."] unless amount_cents.is_a?(Integer) && amount_cents >= 0

        payment = old.customer_payment
        unless payment.voided?
          voided = CustomerAccounts::VoidPayment.call(customer_payment: payment, user: @user, reason: "Corrección de cobro de reparto (#{@route.title} del #{fmt(@route.date)}): #{reason}")
          next voided.errors.map { |e| "#{e} Avisale a administración." } unless voided.ok?
        end
        old.update!(voided_at: Time.current, voided_by: @user, void_reason: reason)

        unidentified = old.unidentified? if unidentified.nil?
        if amount_cents.positive?
          allocations ||= unidentified ? {} : redistribute(old, amount_cents)
          outcome = register(old.delivery_stop, amount_cents, allocations, unidentified, token, replaces: old, event: false)
          next outcome if outcome.is_a?(Array)

          Events.record(@route, @user, "collection_corrected", stop: old.delivery_stop, reason: reason,
                        before_cents: old.amount_cents, after_cents: amount_cents, old_collection_id: old.id, collection_id: outcome.id,
                        summary: "Corrigió el cobro de #{old.customer.name}: de $#{money(old.amount_cents)} a $#{money(amount_cents)}. Motivo: #{reason}.")
          outcome
        else
          Events.record(@route, @user, "collection_voided", stop: old.delivery_stop, reason: reason,
                        before_cents: old.amount_cents, after_cents: 0, old_collection_id: old.id,
                        summary: "Anuló el cobro de $#{money(old.amount_cents)} de #{old.customer.name}. Motivo: #{reason}.")
          old
        end
      end
    end

    # "No me pagaron": no hay dinero que registrar; queda la respuesta en la parada.
    def report_unpaid(stop)
      run(nil) do
        stop = active_order_stop(stop)
        next ["Esta parada no es un pedido."] unless stop

        if stop.payment_report != "none"
          stop.update!(payment_report: "none", payment_reported_at: Time.current)
          Events.record(@route, @user, "payment_reported", stop: stop, summary: "#{@user.display_name} informó que #{stop.display_name} no pagó.")
        end
        stop
      end
    end

    private

    def run(token)
      result = nil
      DeliveryRoute.transaction do
        @route = DeliveryRoute.lock.find(@route.id)
        if token && (existing = DeliveryCollection.find_by(request_token: token))
          result = existing.delivery_route_id == @route.id ? Result.new(collection: existing, errors: [], already: true) : failure("No se pudo registrar el cobro.")
          next
        end
        if (denied = Access.money_error(@route, @user))
          result = failure(denied)
          raise ActiveRecord::Rollback
        end

        outcome = yield
        if outcome.is_a?(Array)
          result = Result.new(errors: outcome, already: false)
          raise ActiveRecord::Rollback
        end
        result = Result.new(collection: outcome.is_a?(DeliveryCollection) ? outcome : nil, errors: [], already: false)
      end
      result
    rescue ActiveRecord::RecordNotUnique, ActiveRecord::StatementInvalid => e
      raise unless e.is_a?(ActiveRecord::RecordNotUnique) || e.cause.is_a?(PG::InFailedSqlTransaction)

      existing = token && DeliveryCollection.find_by(request_token: token)
      existing ? Result.new(collection: existing, errors: [], already: true) : failure("No se pudo registrar el cobro. Volvé a intentar.")
    end

    # Devuelve el DeliveryCollection creado o un array de errores.
    def register(stop, amount_cents, allocations, unidentified, token, replaces: nil, report: nil, event: true)
      return ["Escribí cuánto te pagaron."] unless amount_cents.is_a?(Integer) && amount_cents.positive?

      allocations = unidentified ? {} : normalize(allocations)
      return ["Lo repartido entre pedidos ($#{money(allocations.values.sum)}) supera lo que te pagaron ($#{money(amount_cents)})."] if allocations.values.sum > amount_cents

      paid = CustomerAccounts::RegisterPayment.call(
        customer: stop.customer, user: @user, amount_cents: amount_cents, paid_on: Date.current,
        payment_method: PAYMENT_METHOD, allocations: allocations, request_token: "reparto-#{token}",
        note: payment_note(stop, unidentified)
      )
      return paid.errors unless paid.ok?

      collection = @route.collections.create!(
        delivery_stop: stop, customer: stop.customer, customer_payment: paid.customer_payment,
        amount_cents: amount_cents, credit_cents: paid.credit_cents, mode: unidentified ? "unidentified" : "allocated",
        allocations: allocations.transform_keys(&:to_s), request_token: token, created_by: @user, replaces: replaces
      )
      stop.update!(payment_report: report, payment_reported_at: Time.current) if report
      if event
        detail = unidentified ? " (a identificar)" : (paid.credit_cents.positive? ? " ($#{money(paid.credit_cents)} a favor del cliente)" : "")
        Events.record(@route, @user, "collection_recorded", stop: stop, collection_id: collection.id, amount_cents: amount_cents,
                      allocations: collection.allocations, summary: "#{@user.display_name} cobró $#{money(amount_cents)} en efectivo a #{stop.customer.name}#{detail}.")
      end
      collection
    end

    def active_order_stop(stop)
      stop = @route.stops.active.find_by(id: stop.id)
      stop if stop&.order?
    end

    def normalize(allocations)
      (allocations || {}).each_with_object({}) do |(id, cents), memo|
        id = Integer(id.to_s, exception: false)
        memo[id] = cents if id && cents.is_a?(Integer) && cents.positive?
      end
    end

    # Reparte el importe corregido entre los pedidos del cobro original, en el mismo orden,
    # hasta el saldo de cada uno (ya sin el cobro anulado). Lo que sobra: saldo a favor.
    def redistribute(old, amount_cents)
      ids = old.allocation_map.keys
      ids = [old.delivery_stop.order_id] if ids.empty?
      orders = Order.where(id: ids).index_by(&:id).values_at(*ids).compact
      CustomerAccounts::Distribution.suggest(orders, amount_cents).allocations
    end

    def payment_note(stop, unidentified)
      ["Cobro de reparto: #{@route.title} del #{fmt(@route.date)}", "parada #{stop.position}",
       ("A identificar" if unidentified)].compact.join(" · ")
    end

    def failure(message)
      Result.new(errors: [message], already: false)
    end

    def money(cents)
      CustomerAccounts::Money.format_pesos(cents)
    end

    def fmt(date)
      I18n.l(date, format: "%d/%m")
    end
  end
end
