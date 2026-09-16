module CostPropagating
  extend ActiveSupport::Concern

  private

  # Envuelve una mutación (bloque) y, si termina en algo truthy, propaga el
  # cambio desde `source` en la MISMA transacción — nada de callbacks
  # encadenados. Si Costing::PropagateCostChange falla, todo se revierte:
  # la mutación original nunca queda aplicada sola.
  #
  # `source` puede ser el propio objeto mutado, o nil cuando el caller ya
  # decidió que este cambio puntual no amerita propagar (ej. solo cambió
  # "position", o solo "name" en una Preparation) — en ese caso el bloque
  # corre igual, sin transacción extra ni propagación.
  def propagate_after(source)
    return yield if source.nil?

    # requires_new: true fuerza un SAVEPOINT real en vez de "sumarse" a una
    # transacción ya abierta (ej. la que envuelve cada test en Rails, o
    # cualquier composición futura) — sin esto, si Costing::PropagateCostChange
    # falla y el error se rescata acá adentro, Rails nunca llega a emitir el
    # ROLLBACK real: la única transacción "dueña" del BEGIN es la de más
    # afuera, y esa nunca se entera del error porque lo atrapamos antes.
    # Con requires_new, este bloque es dueño de su propio SAVEPOINT pase lo
    # que pase alrededor, así que su rollback es real siempre.
    ActiveRecord::Base.transaction(requires_new: true) do
      result = yield
      Costing::PropagateCostChange.call(source) if result
      result
    end
  rescue Costing::PropagateCostChange::PropagationError, Costing::SyncProductCost::SyncError => e
    @cost_propagation_error = e.message
    Rails.logger.error("[CostPropagating] #{e.class}: #{e.message}")
    false
  end
end
