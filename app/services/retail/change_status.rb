module Retail
  # Cambia el estado operativo (independiente del de pago) y deja el cambio registrado.
  # Cancelar saca el pedido de producción y de la demanda de stock; si ya se había descontado
  # stock, Stock::DispatchReconciler lo devuelve con un movimiento de corrección (mismo
  # mecanismo que los mayoristas). Los pagos y el historial se conservan intactos.
  class ChangeStatus
    def self.call(**args)
      new(**args).call
    end

    def initialize(order:, to_status:, user:, note: nil)
      @order = order
      @to_status = to_status.to_s
      @user = user
      @note = note.to_s.strip.presence
    end

    def call
      return Result.new(record: @order, errors: ["El estado no es válido."]) unless RetailOrder.statuses.key?(@to_status)

      result = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        order = RetailOrder.lock.find(@order.id)

        if order.status == @to_status
          result = Result.new(record: order, errors: ["El pedido ya está en estado #{order.status_label}."])
          next
        end

        from = order.status
        order.update!(status: @to_status)
        RetailOrderStatusChange.create!(retail_order: order, from_status: from, to_status: @to_status, user: @user, note: @note)
        Stock::DispatchReconciler.call(order)
        result = Result.new(record: order, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(record: @order, errors: e.record.errors.full_messages)
    end
  end
end
