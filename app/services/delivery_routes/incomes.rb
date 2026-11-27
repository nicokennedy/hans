module DeliveryRoutes
  class Incomes
    Result = Struct.new(:income, :error, keyword_init: true)

    def initialize(route, user)
      @route = route
      @user = user
    end

    def save(kind:, description:, amount_cents:, token:, old: nil, reason: nil)
      return Result.new(error: "Volvé a abrir el formulario.") if token.blank?

      @route.with_lock do
        denied = Access.money_error(@route, @user)
        next Result.new(error: denied) if denied
        next Result.new if @route.incomes.exists?(request_token: token)

        old = @route.incomes.lock.find(old.id) if old
        next Result.new(error: "Este ingreso ya fue corregido.") if old&.voided?
        next Result.new(error: "Escribí el motivo de la corrección.") if old && reason.blank?
        next Result.new(error: "Escribí un importe válido.") unless amount_cents.is_a?(Integer) && amount_cents >= 0

        removing = old && amount_cents.zero?
        income = unless removing
          @route.incomes.build(kind: kind, description: description.to_s.squish, amount_cents: amount_cents,
                               request_token: token, created_by: @user, replaces: old)
        end
        next Result.new(error: income.errors.full_messages.to_sentence) if income && !income.valid?

        old&.update!(voided_at: Time.current, voided_by: @user, void_reason: reason)
        income&.save!
        if income && old&.evidence&.attached?
          income.evidence.attach(old.evidence.blob)
        end
        action = removing ? "income_voided" : old ? "income_corrected" : "income_recorded"
        Events.record(@route, @user, action, reason: reason, income_id: income&.id, old_income_id: old&.id,
                      before_cents: old&.amount_cents, after_cents: amount_cents,
                      summary: "#{@user.display_name} #{removing ? 'anuló' : old ? 'corrigió' : 'registró'} un ingreso: #{(income || old).kind_label}.")
        Result.new(income: income)
      end
    end
  end
end
