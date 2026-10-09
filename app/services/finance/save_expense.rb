module Finance
  # Alta y edición de un gasto general, con su obligación, en una transacción.
  # Opcionalmente registra el pago en el mismo momento. No toca stock, recetas ni costos.
  class SaveExpense
    def self.call(**args)
      new(**args).call
    end

    # attributes: supplier_id (opcional), expense_category_id, amount_cents, accrual_on, due_on,
    #             document_type, document_number, notes
    def initialize(user:, attributes:, expense: nil, upload: nil, pay_now: nil, recurrence: nil, occurrence_on: nil)
      @user = user
      @attributes = attributes
      @expense = expense
      @upload = upload
      @pay_now = pay_now
      @recurrence = recurrence
      @occurrence_on = occurrence_on
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        expense = @expense || Expense.new
        new_record = expense.new_record?
        obligation = expense.obligation || Obligation.new
        supplier = @attributes[:supplier_id].present? ? Supplier.find_by(id: @attributes[:supplier_id]) : nil
        errors = []
        errors << "El proveedor elegido no existe." if @attributes[:supplier_id].present? && supplier.nil?

        category = ExpenseCategory.find_by(id: @attributes[:expense_category_id])
        errors << "Elegí una categoría." if category.nil?
        expense.assign_attributes(expense_category: category)
        expense.assign_attributes(expense_recurrence: @recurrence, occurrence_on: @occurrence_on) if @recurrence

        errors.concat(expense.errors.full_messages) unless expense.valid? || category.nil?
        obligation.assign_attributes(@attributes.slice(:accrual_on, :due_on, :document_type, :document_number, :notes, :amount_cents).merge(supplier: supplier))
        obligation.user ||= @user
        obligation.source = expense
        errors.concat(obligation.errors.full_messages) unless obligation.valid?

        if errors.any?
          result = Result.new(record: expense, errors: errors.uniq)
          raise ActiveRecord::Rollback
        end

        expense.save!
        obligation.source = expense
        obligation.save!
        AdministrationAttachment.build_from_upload(expense, @upload, user: @user).save! if @upload

        if new_record && @pay_now && @pay_now[:amount_cents].to_i.positive?
          paid = RegisterPayment.call(supplier: supplier, user: @user, amount_cents: @pay_now[:amount_cents], paid_on: @pay_now[:paid_on] || obligation.accrual_on,
                                      payment_method: @pay_now[:payment_method], allocations: { obligation.id => @pay_now[:amount_cents] },
                                      reference: @pay_now[:reference], request_token: @pay_now[:request_token])
          unless paid.ok?
            result = Result.new(record: expense, errors: paid.errors.map { |e| "Pago: #{e}" })
            raise ActiveRecord::Rollback
          end
        end

        result = Result.new(record: expense.reload, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(record: @expense, errors: e.record.errors.full_messages)
    end
  end
end
