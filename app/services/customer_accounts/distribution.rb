module CustomerAccounts
  # Pedidos de un cliente que se pueden cobrar hoy, y la distribución automática de un
  # importe entre ellos.
  class Distribution
    # Pedidos NO cancelados con saldo pendiente, del más antiguo (por fecha de
    # entrega) al más nuevo; a igual fecha, el creado primero.
    def self.pending_orders(customer)
      customer.orders.not_canceled
              .where("orders.total_cents > orders.amount_paid_cents")
              .order(:delivery_date, :created_at, :id)
    end

    # orders: pedidos ya ordenados (ver pending_orders). Devuelve { order_id => cents }
    # con solo los pedidos que reciben algo, y el sobrante sin aplicar. Nunca asigna más
    # que el saldo de cada pedido, ni importes negativos, ni más del total recibido.
    Result = Struct.new(:allocations, :unapplied_cents, keyword_init: true)

    def self.suggest(orders, amount_cents)
      remaining = [amount_cents.to_i, 0].max
      allocations = {}

      orders.each do |order|
        break if remaining <= 0

        balance = order.balance_due_cents
        next unless balance.positive?

        applied = [balance, remaining].min
        allocations[order.id] = applied
        remaining -= applied
      end

      Result.new(allocations: allocations, unapplied_cents: remaining)
    end
  end
end
