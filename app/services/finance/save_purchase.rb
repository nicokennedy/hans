module Finance
  # Alta y edición de una compra con sus ítems, en una transacción: compra, ítems y su
  # obligación (la deuda) se guardan juntos o no se guarda nada. Opcionalmente registra el
  # pago en el mismo momento ("pagar ahora").
  #
  # IMPORTANTE (etapa 1): no toca stock, materias primas, recetas ni costos. Los ítems solo
  # quedan registrados con descripción, cantidad, unidad y precio.
  class SavePurchase
    def self.call(**args)
      new(**args).call
    end

    # attributes: supplier_id, accrual_on, due_on, document_type, document_number, notes
    # totals: discount_cents, taxes_cents, adjustments_cents (enteros)
    # items: [{ id:, description:, quantity: BigDecimal, unit:, unit_price_cents: Integer }]
    # pay_now: { amount_cents:, payment_method:, reference:, paid_on:, request_token: } o nil
    def initialize(user:, attributes:, totals:, items:, purchase: nil, upload: nil, pay_now: nil)
      @user = user
      @attributes = attributes
      @totals = totals
      @items = items
      @purchase = purchase
      @upload = upload
      @pay_now = pay_now
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        purchase = @purchase || Purchase.new
        new_record = purchase.new_record?
        obligation = purchase.obligation || Obligation.new
        supplier = Supplier.find_by(id: @attributes[:supplier_id])
        errors = []
        errors << "Elegí un proveedor." if supplier.nil?

        purchase.assign_attributes(@totals)
        errors.concat(sync_items(purchase))
        purchase.recalculate_subtotal
        errors << "Cargá al menos un ítem de mercadería." if purchase.items.reject(&:marked_for_destruction?).empty?

        errors.concat(purchase.errors.full_messages) unless purchase.valid?
        obligation.assign_attributes(@attributes.slice(:accrual_on, :due_on, :document_type, :document_number, :notes).merge(supplier: supplier, amount_cents: purchase.total_cents))
        obligation.user ||= @user
        obligation.source = purchase
        errors.concat(obligation.errors.full_messages) unless obligation.valid?

        if errors.any?
          result = Result.new(record: purchase, errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        purchase.save!
        obligation.source = purchase
        obligation.save!
        AdministrationAttachment.build_from_upload(purchase, @upload, user: @user).save! if @upload

        if new_record && @pay_now && @pay_now[:amount_cents].to_i.positive?
          paid = RegisterPayment.call(supplier: supplier, user: @user, amount_cents: @pay_now[:amount_cents], paid_on: @pay_now[:paid_on] || obligation.accrual_on,
                                      payment_method: @pay_now[:payment_method], allocations: { obligation.id => @pay_now[:amount_cents] },
                                      reference: @pay_now[:reference], request_token: @pay_now[:request_token])
          unless paid.ok?
            result = Result.new(record: purchase, errors: paid.errors.map { |e| "Pago: #{e}" })
            raise ActiveRecord::Rollback
          end
        end

        result = Result.new(record: purchase.reload, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(record: @purchase, errors: e.record.errors.full_messages)
    end

    private

    # Actualiza los ítems existentes (por id, conservando su historial), crea los nuevos y
    # marca para borrar los que ya no están. Devuelve los errores de validación por fila.
    def sync_items(purchase)
      existing = purchase.items.index_by(&:id)
      kept = []
      errors = []

      @items.each_with_index do |row, index|
        item = row[:id].present? ? existing[row[:id].to_i] : nil

        if row[:id].present? && item.nil?
          errors << "Ítem #{index + 1}: no pertenece a esta compra."
          next
        end

        item ||= purchase.items.build
        item.assign_attributes(description: row[:description], quantity: row[:quantity], unit: row[:unit], unit_price_cents: row[:unit_price_cents], position: index)
        kept << item.id if item.persisted?
        errors << "Ítem #{index + 1}: #{item.errors.full_messages.to_sentence}" unless item.valid?
      end

      existing.each_value { |item| item.mark_for_destruction unless kept.include?(item.id) }
      errors
    end
  end
end
