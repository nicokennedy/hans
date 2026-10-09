module Finance
  # Borra una compra o un gasto SOLO si nunca tuvo pagos (ni siquiera anulados) y no es la
  # ocurrencia de una recurrencia (esas se anulan, para que no se vuelvan a generar). En
  # cualquier otro caso hay que anular, nunca borrar un movimiento financiero.
  class DestroySource
    def self.call(source)
      obligation = source.obligation
      return Result.new(errors: ["Tiene pagos registrados (aunque estén anulados): no se puede borrar, solo anular."]) if obligation&.applications&.exists?
      return Result.new(errors: ["Es una ocurrencia de un gasto recurrente: anulala en vez de borrarla."]) if source.respond_to?(:expense_recurrence_id) && source.expense_recurrence_id.present?

      ActiveRecord::Base.transaction(requires_new: true) do
        obligation&.destroy!
        source.reload.destroy!
      end

      Result.new(errors: [])
    rescue ActiveRecord::DeleteRestrictionError, ActiveRecord::RecordNotDestroyed => e
      Result.new(errors: [e.message])
    end
  end
end
