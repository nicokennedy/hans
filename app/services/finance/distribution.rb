module Finance
  # Obligaciones pendientes de un proveedor y la propuesta automática de imputación de
  # un pago: primero la que vence antes (sin vencimiento al final) y, a igual vencimiento,
  # la de fecha de compra/devengamiento más antigua. Nunca más que el saldo de cada una.
  class Distribution
    Suggestion = Struct.new(:allocations, :unapplied_cents, keyword_init: true)

    def self.pending_obligations(supplier)
      supplier.obligations.outstanding.with_paid.oldest_first
    end

    def self.suggest(obligations, amount_cents)
      remaining = [amount_cents.to_i, 0].max
      allocations = {}

      obligations.each do |obligation|
        break if remaining <= 0

        balance = obligation.balance_cents
        next unless balance.positive?

        applied = [balance, remaining].min
        allocations[obligation.id] = applied
        remaining -= applied
      end

      Suggestion.new(allocations: allocations, unapplied_cents: remaining)
    end
  end
end
