module DeliveryRoutes
  # Lo que registra el repartidor en su celular (R3): entregué, no pude, hecho. Cada operación:
  # una transacción con la parada (y el pedido) bloqueados, y es IDEMPOTENTE: si el repartidor
  # toca dos veces o reintenta después de un corte, no se duplica nada (el segundo intento
  # devuelve "ya estaba registrado").
  #
  # "Entregué" pasa el pedido mayorista a Entregado (decisión D6) con update_columns: no
  # recalcula totales ni dispara la reconciliación de stock, no crea pagos ni toca cuentas
  # corrientes. Queda en OrderEvent (historial del pedido) y DeliveryEvent (del recorrido).
  class Deliveries
    Result = Struct.new(:stop, :errors, :already, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    def initialize(stop, user)
      @stop = stop
      @user = user
    end

    def deliver
      record do |stop|
        next error("Esta parada no es un pedido.") unless stop.order?
        next already if stop.delivery_status == "delivered"

        order = Order.lock.find(stop.order_id)
        next error("Este pedido fue cancelado. Avisale a administración.") if order.canceled?

        now = Time.current
        stop.update!(delivery_status: "delivered", not_delivered_reason: nil, delivery_recorded_at: now, delivery_recorded_by: @user)
        unless order.delivered?
          OrderEvent.create!(order: order, user: @user, event_type: "status_change", field_name: "status",
                             old_value: order.status, new_value: "delivered", reason: "Entregado por reparto (recorrido ##{stop.delivery_route_id})")
          order.update_columns(status: "delivered", updated_at: now)
        end
        Events.record(stop.delivery_route, @user, "stop_delivered", stop: stop, order_id: order.id,
                      summary: "#{@user.display_name} entregó el pedido #{order.number} de #{stop.display_name}.")
        nil
      end
    end

    def not_delivered(reason)
      reason = reason.to_s.squish
      record do |stop|
        next error("Elegí el motivo.") unless DeliveryStop::NOT_DELIVERED_REASONS.include?(reason)
        next error("Ya está registrada como #{stop.delivery_status_label.downcase}. Si fue un error, avisale a administración.") if stop.completed?
        next already if stop.delivery_status == "not_delivered" && stop.not_delivered_reason == reason

        stop.update!(delivery_status: "not_delivered", not_delivered_reason: reason, delivery_recorded_at: Time.current, delivery_recorded_by: @user)
        Events.record(stop.delivery_route, @user, "stop_not_delivered", stop: stop, reason: reason,
                      summary: "#{@user.display_name} no pudo hacer la parada #{stop.display_name}: #{reason.downcase}.")
        nil
      end
    end

    # Paradas manuales (retiro de insumos, compra, gestión): "Listo, lo hice".
    def done
      record do |stop|
        next error("Para un pedido usá \"Sí, lo entregué\".") if stop.order?
        next already if stop.delivery_status == "done"

        stop.update!(delivery_status: "done", not_delivered_reason: nil, delivery_recorded_at: Time.current, delivery_recorded_by: @user)
        Events.record(stop.delivery_route, @user, "stop_done", stop: stop, summary: "#{@user.display_name} hizo la parada \"#{stop.title}\".")
        nil
      end
    end

    private

    def record
      outcome = nil
      DeliveryStop.transaction do
        stop = DeliveryStop.lock.find(@stop.id)
        outcome =
          if stop.removed?
            error("Esta parada ya no está en tu recorrido. Volvé a la lista.")
          elsif !stop.delivery_route.open_for_driver?
            error("Ya enviaste la rendición de este reparto: no se puede cambiar. Si hay un error, avisale a administración.")
          else
            yield(stop) || Result.new(stop: stop, errors: [], already: false)
          end
        raise ActiveRecord::Rollback unless outcome.ok?
      end
      outcome
    end

    def error(message)
      Result.new(stop: @stop, errors: [message], already: false)
    end

    def already
      Result.new(stop: @stop.reload, errors: [], already: true)
    end
  end
end
