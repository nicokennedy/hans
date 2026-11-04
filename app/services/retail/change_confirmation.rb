module Retail
  # Confirma o rechaza un pedido minorista pendiente de confirmación (los de la tienda online).
  # Con el pedido bloqueado (SELECT ... FOR UPDATE), así dos confirmaciones simultáneas no
  # pueden aplicarse dos veces. Transiciones válidas, y solo estas:
  #   awaiting -> confirmed   registra fecha y usuario; desde ese momento el pedido cuenta para
  #                           producción y stock (RetailOrder.committed) y se concilia el stock
  #                           con el mecanismo de siempre (Stock::DispatchReconciler, por delta:
  #                           nunca duplica movimientos)
  #   awaiting -> rejected    exige motivo; el pedido queda fuera de producción y stock para
  #                           siempre (un rechazo no se puede revertir ni confirmar después)
  # Un pedido cancelado no se puede confirmar. Todo cambio queda en el historial.
  class ChangeConfirmation
    ACTIONS = %w[confirm reject].freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(order:, action:, user:, reason: nil)
      @order = order
      @action = action.to_s
      @user = user
      @reason = reason.to_s.strip.presence
    end

    def call
      return failure("La acción no es válida.") unless ACTIONS.include?(@action)
      return failure("Indicá el motivo del rechazo.") if @action == "reject" && @reason.nil?
      return failure("El motivo es demasiado largo (máximo 1000 caracteres).") if @reason && @reason.length > 1000

      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        order = RetailOrder.lock.find(@order.id)
        @order = order

        if (error = transition_error(order))
          result = failure(error)
          next
        end

        from = order.confirmation_status
        @action == "confirm" ? confirm(order) : reject(order)
        order.retail_order_confirmation_changes.create!(from_status: from, to_status: order.confirmation_status, user: @user, note: @reason)
        Stock::DispatchReconciler.call(order)
        result = Result.new(record: order, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(record: @order, errors: e.record.errors.full_messages)
    end

    private

    def transition_error(order)
      return "El pedido ya está confirmado." if order.confirmation_confirmed?
      return "El pedido fue rechazado: no se puede #{@action == 'confirm' ? 'confirmar' : 'rechazar de nuevo'}." if order.confirmation_rejected?
      return "El pedido está cancelado: no se puede confirmar." if @action == "confirm" && order.canceled?

      nil
    end

    def confirm(order)
      order.update!(confirmation_status: "confirmed", confirmed_at: Time.current, confirmed_by: @user)
    end

    def reject(order)
      order.update!(confirmation_status: "rejected", rejected_at: Time.current, rejected_by: @user, rejection_reason: @reason)
    end

    def failure(message)
      Result.new(record: @order, errors: [message])
    end
  end
end
