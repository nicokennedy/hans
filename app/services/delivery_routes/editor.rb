module DeliveryRoutes
  # Cambios de administración sobre un recorrido guardado. Cada operación: una transacción con
  # el recorrido bloqueado, validaciones, posiciones renumeradas 1..n y un evento en el
  # historial. Nunca modifica pedidos, pagos, stock ni cuentas corrientes.
  class Editor
    def initialize(route, user)
      @route = route
      @user = user
    end

    def add_orders(order_ids, reason: nil)
      ids = Array(order_ids).map(&:to_i).uniq.reject(&:zero?)
      return failure("Elegí al menos un pedido.") if ids.empty?

      change do
        orders = Order.for_delivery_date(@route.date).where(id: ids).includes(:customer).to_a
        errors = []
        errors << "Algunos pedidos no son del #{fmt(@route.date)} o están cancelados." if orders.size < ids.size
        DeliveryStop.active.where(order_id: ids).includes(:delivery_route, order: :customer).each do |stop|
          where = stop.delivery_route_id == @route.id ? "este recorrido" : "#{stop.delivery_route.title} del #{fmt(stop.delivery_route.date)}"
          errors << "#{stop.display_name} (#{stop.order.number}) ya está en #{where}."
        end
        next errors if errors.any?

        orders.each do |order|
          stop = @route.stops.create!(kind: "order", order: order, customer: order.customer, position: next_position)
          Events.record(@route, @user, "stop_added", stop: stop, reason: reason,
                        summary: "Agregó el pedido #{order.number} de #{stop.display_name} al final.")
        end
        []
      end
    end

    def add_manual(kind:, title:, address: nil, notes: nil, reason: nil)
      change do
        stop = @route.stops.build(kind: kind.to_s, title: title.to_s.squish.presence, address: address.to_s.squish.presence,
                                  notes: notes.to_s.strip.presence, position: next_position)
        stop.errors.add(:kind, "no es válido") unless DeliveryStop::MANUAL_KINDS.key?(stop.kind)
        next stop.errors.full_messages if stop.errors.any? || !stop.valid?

        stop.save!
        Events.record(@route, @user, "stop_added", stop: stop, reason: reason,
                      summary: "Agregó la parada \"#{stop.title}\" (#{stop.kind_label.downcase}) al final.")
        []
      end
    end

    def update_manual(stop, title:, address: nil, notes: nil, reason: nil)
      change do
        stop = active_stop(stop)
        next ["Solo se editan las paradas manuales. Los datos del pedido se cambian desde Pedidos."] if stop.order?

        before = stop.slice(:title, :address, :notes)
        stop.assign_attributes(title: title.to_s.squish.presence, address: address.to_s.squish.presence, notes: notes.to_s.strip.presence)
        next stop.errors.full_messages unless stop.valid?
        next [] unless stop.changed?

        stop.save!
        Events.record(@route, @user, "stop_updated", stop: stop, reason: reason, before: before, after: stop.slice(:title, :address, :notes),
                      summary: "Editó la parada \"#{stop.title}\".")
        []
      end
    end

    def move(stop, direction)
      change do
        stop = active_stop(stop)
        list = @route.stops.active.to_a
        index = list.index(stop)
        target = direction.to_s == "up" ? index - 1 : index + 1
        next [] if target.negative? || target >= list.size

        list.insert(target, list.delete_at(index))
        renumber(list)
        Events.record(@route, @user, "stop_moved", stop: stop, from: index + 1, to: target + 1,
                      summary: "Movió #{stop.display_name} de la posición #{index + 1} a la #{target + 1}.")
        []
      end
    end

    def remove(stop, removal_kind:, reason: nil)
      change do
        stop = active_stop(stop)
        next ["#{stop.display_name} ya está registrada como #{stop.delivery_status_label.downcase}: no se puede quitar."] if stop.completed?
        next ["Para pasar el pedido a otro repartidor usá \"Pasar a otro repartidor\"."] if removal_kind.to_s == "transferred"
        stop.assign_attributes(removed_at: Time.current, removed_by: @user, removal_kind: removal_kind.to_s, removal_reason: reason.to_s.strip.presence)
        next stop.errors.full_messages unless stop.valid?

        stop.save!
        renumber(@route.stops.active.to_a)
        Events.record(@route, @user, "stop_removed", stop: stop, reason: stop.removal_reason, removal_kind: stop.removal_kind,
                      summary: "Quitó #{stop.display_name} del recorrido: #{stop.removal_label.downcase}.")
        []
      end
    end

    # Pasa un pedido no entregado a otro recorrido de la misma fecha: la parada de origen queda
    # quitada ("Pasó a otro repartidor") y se crea una nueva al final del destino. El pedido no
    # se toca. Queda en el historial de los dos recorridos.
    def transfer(stop, target)
      change do
        stop = active_stop(stop)
        next ["Solo se pasan paradas de pedidos. Las paradas manuales se quitan y se agregan en el otro recorrido."] unless stop.order?
        next ["#{stop.display_name} ya está entregado: no se puede pasar a otro reparto."] if stop.completed?
        next ["Elegí otro recorrido del #{fmt(@route.date)}."] if target.nil? || target.id == @route.id || target.date != @route.date

        target.lock!
        next ["#{target.title} ya no está en preparación."] unless target.editable?

        from_name = @route.title
        stop.update!(removed_at: Time.current, removed_by: @user, removal_kind: "transferred",
                     removal_reason: target.title)
        renumber(@route.stops.active.to_a)
        new_stop = target.stops.create!(kind: "order", order: stop.order, customer: stop.customer,
                                        position: target.stops.active.maximum(:position).to_i + 1)
        Events.record(@route, @user, "stop_transferred_out", stop: stop, to_route_id: target.id,
                      summary: "Pasó #{stop.display_name} (#{stop.order.number}) a #{target.title}.")
        Events.record(target, @user, "stop_transferred_in", stop: new_stop, from_route_id: @route.id,
                      summary: "Recibió #{stop.display_name} (#{stop.order.number}) de #{from_name}.")
        []
      end
    end

    def restore(stop)
      change do
        stop = @route.stops.removed.find(stop.id)
        if stop.order?
          next ["El pedido #{stop.order.number} está cancelado: no se puede volver a agregar."] if stop.order.canceled?
          next ["La fecha del pedido #{stop.order.number} ya no es el #{fmt(@route.date)}."] if stop.order.delivery_date != @route.date
          other = DeliveryStop.active.find_by(order_id: stop.order_id)
          next ["#{stop.display_name} ya está en #{other.delivery_route.title} del #{fmt(other.delivery_route.date)}."] if other
        end

        stop.update!(removed_at: nil, removed_by: nil, removal_kind: nil, removal_reason: nil, position: next_position)
        Events.record(@route, @user, "stop_restored", stop: stop, summary: "Volvió a agregar #{stop.display_name} al final.")
        []
      end
    end

    def assign_driver(driver)
      change do
        next ["Elegí un repartidor: todo recorrido tiene un responsable."] if driver.nil?
        next ["Ese usuario no es repartidor."] unless driver.driver?
        next ["#{driver.display_name} tiene el acceso desactivado."] unless driver.active?
        next [] if @route.driver_id == driver&.id

        previous = @route.driver&.display_name
        @route.update!(driver: driver)
        Events.record(@route, @user, "driver_assigned", before: previous, after: driver.display_name,
                      summary: previous ? "Pasó el recorrido de #{previous} a #{driver.display_name}." : "Asignó el recorrido a #{driver.display_name}.")
        []
      end
    end

    private

    def change
      errors = []
      DeliveryRoute.transaction do
        @route.lock!
        unless @route.editable?
          errors = ["El recorrido ya no está en preparación: no se puede modificar desde acá."]
          raise ActiveRecord::Rollback
        end
        errors = Array(yield)
        raise ActiveRecord::Rollback if errors.any?
      end
      Result.new(route: @route, errors: errors)
    rescue ActiveRecord::RecordNotUnique
      failure("Ese pedido ya está en un recorrido (otro usuario lo agregó al mismo tiempo).")
    rescue ActiveRecord::RecordNotFound
      failure("La parada ya no existe o ya fue quitada.")
    end

    def failure(message)
      Result.new(route: @route, errors: [message])
    end

    def active_stop(stop)
      @route.stops.active.find(stop.id)
    end

    def next_position
      @route.stops.active.maximum(:position).to_i + 1
    end

    def renumber(list)
      list.each_with_index { |s, i| s.update_column(:position, i + 1) if s.position != i + 1 }
    end

    def fmt(date)
      I18n.l(date, format: "%d/%m")
    end
  end
end
