module CustomerAccounts
  # Validación de una distribución { order_id => cents } contra el estado ACTUAL de la
  # base (siempre después de bloquear cliente y pedidos): pedidos del cliente, no
  # cancelados, importes enteros positivos y sin superar el saldo de cada pedido.
  # Devuelve [pedidos_bloqueados_por_id, errores].
  module AllocationValidator
    module_function

    def call(customer, allocations)
      errors = []
      normalized = {}

      allocations.each do |raw_id, raw_cents|
        id = Integer(raw_id.to_s, exception: false)
        cents = raw_cents.is_a?(Integer) ? raw_cents : nil

        if id.nil? || cents.nil?
          errors << "Hay una distribución con datos inválidos."
        elsif cents.negative?
          errors << "No se permiten importes negativos."
        elsif cents.positive?
          normalized[id] = cents
        end
      end

      orders = Order.where(id: normalized.keys).lock.order(:id).index_by(&:id)

      normalized.each do |id, cents|
        order = orders[id]

        if order.nil? || order.customer_id != customer.id
          errors << "El pedido ##{id} no existe o no pertenece a este cliente."
        elsif order.canceled?
          errors << "El pedido #{order.number} está cancelado: no se le pueden aplicar pagos."
        elsif cents > order.balance_due_cents
          errors << "El pedido #{order.number} tiene un saldo de $#{Money.format_pesos([order.balance_due_cents, 0].max)} y se intentó aplicar $#{Money.format_pesos(cents)}."
        end
      end

      [normalized, orders, errors.uniq]
    end
  end
end
