module Finance
  # Valida una imputación { obligation_id => centavos } contra el estado ACTUAL, siempre
  # con las obligaciones bloqueadas: del mismo proveedor, no anuladas, importes enteros
  # positivos y sin superar el saldo de cada una. Devuelve [normalizada, obligaciones, errores].
  module AllocationValidator
    module_function

    def call(supplier, allocations)
      errors = []
      normalized = {}

      allocations.each do |raw_id, raw_cents|
        id = Integer(raw_id.to_s, exception: false)
        cents = raw_cents.is_a?(Integer) ? raw_cents : nil

        if id.nil? || cents.nil?
          errors << "Hay una imputación con datos inválidos."
        elsif cents.negative?
          errors << "No se permiten importes negativos."
        elsif cents.positive?
          normalized[id] = cents
        end
      end

      obligations = Obligation.where(id: normalized.keys).lock.order(:id).index_by(&:id)

      normalized.each do |id, cents|
        obligation = obligations[id]

        if obligation.nil? || obligation.supplier_id != supplier&.id
          errors << "La obligación ##{id} no existe o no corresponde a este proveedor."
        elsif obligation.voided?
          errors << "#{obligation.document_label} está anulada: no admite pagos."
        elsif cents > obligation.balance_cents
          errors << "#{obligation.document_label} tiene un saldo de $#{Money.format_pesos([obligation.balance_cents, 0].max)} y se intentó imputar $#{Money.format_pesos(cents)}."
        end
      end

      [normalized, obligations, errors.uniq]
    end
  end
end
