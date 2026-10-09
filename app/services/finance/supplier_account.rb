module Finance
  # Cuenta corriente de un proveedor, calculada SIEMPRE desde obligaciones, pagos e
  # imputaciones reales (nada se guarda como saldo):
  #   Total de obligaciones − pagos imputados = saldo pendiente de obligaciones
  #   Anticipos disponibles = pagos vigentes − lo imputado de ellos
  #   Saldo neto = saldo pendiente − anticipos disponibles = obligaciones − pagos
  class SupplierAccount
    Entry = Struct.new(:date, :sort, :kind, :record, :debit_cents, :credit_cents, keyword_init: true)

    attr_reader :supplier, :from, :to

    def initialize(supplier, from: nil, to: nil)
      @supplier = supplier
      @from = parse_date(from)
      @to = parse_date(to)
    end

    def invalid_dates?
      @invalid_dates == true
    end

    def obligations
      supplier.obligations
    end

    def total_obligations_cents
      obligations.active.sum(:amount_cents)
    end

    def applied_cents
      OutgoingPaymentApplication.active.where(obligation_id: obligations.active.select(:id)).sum(:amount_cents)
    end

    def pending_cents
      total_obligations_cents - applied_cents
    end

    def payments_cents
      supplier.outgoing_payments.active.sum(:amount_cents)
    end

    def advance_cents
      payments_cents - OutgoingPaymentApplication.active.where(outgoing_payment_id: supplier.outgoing_payments.active.select(:id)).sum(:amount_cents)
    end

    def net_cents
      pending_cents - advance_cents
    end

    # Movimientos en orden cronológico (los anulados se muestran pero no suman). El rango de
    # fechas filtra lo que se lista; los totales de arriba son siempre los reales.
    def entries
      @entries ||= begin
        debts = obligations.includes(:source).map do |obligation|
          Entry.new(date: obligation.accrual_on, sort: obligation.created_at, kind: obligation.purchase? ? :purchase : :expense, record: obligation,
                    debit_cents: obligation.voided? ? 0 : obligation.amount_cents, credit_cents: 0)
        end
        pays = supplier.outgoing_payments.includes(applications: :obligation).map do |payment|
          Entry.new(date: payment.paid_on, sort: payment.created_at, kind: :payment, record: payment, debit_cents: 0, credit_cents: payment.voided? ? 0 : payment.amount_cents)
        end

        all = (debts + pays).sort_by { |e| [e.date, e.sort] }
        running = 0
        all.each do |e|
          running += e.debit_cents - e.credit_cents
          balance = running
          e.define_singleton_method(:running_cents) { balance }
        end
        all.select { |e| (from.nil? || e.date >= from) && (to.nil? || e.date <= to) }
      end
    end

    private

    def parse_date(value)
      return nil if value.blank?

      Date.iso8601(value.to_s)
    rescue ArgumentError, TypeError
      @invalid_dates = true
      nil
    end
  end
end
