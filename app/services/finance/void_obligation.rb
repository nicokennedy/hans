module Finance
  # Anula una compra o un gasto (el registro se conserva, con motivo). No se puede anular
  # mientras tenga pagos imputados vigentes: primero se anulan esos pagos.
  class VoidObligation
    def self.call(**args)
      new(**args).call
    end

    def initialize(obligation:, user:, reason:)
      @obligation = obligation
      @user = user
      @reason = reason.to_s.strip
    end

    def call
      result = nil

      ActiveRecord::Base.transaction(requires_new: true) do
        obligation = Obligation.lock.find(@obligation.id)
        errors = []
        errors << "Ya está anulado." if obligation.voided?
        errors << "El motivo de la anulación es obligatorio." if @reason.blank?
        errors << "Tiene pagos imputados vigentes: anulá primero esos pagos." if obligation.applications.active.exists?

        if errors.any?
          result = Result.new(record: obligation, errors: errors)
          raise ActiveRecord::Rollback
        end

        obligation.update!(voided_at: Time.current, voided_by: @user, void_reason: @reason)
        result = Result.new(record: obligation, errors: [])
      end

      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(errors: e.record.errors.full_messages)
    end
  end
end
