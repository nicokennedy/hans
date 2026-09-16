module RawMaterials
  # Actualiza una RawMaterial y, si el update cambia el unit_cost_cents
  # resultante, deja un RawMaterialCostChange en la misma transacción — así
  # nunca queda una materia prima actualizada sin su registro histórico (ni
  # viceversa). El usuario que hizo el cambio se recibe explícito desde
  # quien llama (el controller, que es el único lugar que legítimamente
  # conoce al current_user) en vez de leerlo de algún estado global.
  class UpdateWithCostHistory
    def self.call(raw_material:, attributes:, changed_by:)
      new(raw_material, attributes, changed_by).call
    end

    def initialize(raw_material, attributes, changed_by)
      @raw_material = raw_material
      @attributes = attributes
      @changed_by = changed_by
    end

    def call
      before = snapshot

      # requires_new: true por el mismo motivo que en CostPropagating#propagate_after
      # — garantiza un SAVEPOINT real y un rollback real de este bloque
      # incluso si quien llama ya está dentro de otra transacción.
      ActiveRecord::Base.transaction(requires_new: true) do
        raw_material.update!(attributes)

        after = snapshot
        if after[:unit_cost_cents] != before[:unit_cost_cents]
          RawMaterialCostChange.create!(
            raw_material: raw_material,
            previous_purchase_price_cents: before[:purchase_price_cents],
            new_purchase_price_cents: after[:purchase_price_cents],
            previous_purchase_quantity: before[:purchase_quantity],
            new_purchase_quantity: after[:purchase_quantity],
            previous_purchase_unit: before[:purchase_unit],
            new_purchase_unit: after[:purchase_unit],
            previous_base_unit: before[:base_unit],
            new_base_unit: after[:base_unit],
            previous_unit_cost_cents: before[:unit_cost_cents],
            new_unit_cost_cents: after[:unit_cost_cents],
            changed_by_user: changed_by
          )

          # Mismo transaction que el update y el historial: si algún Product
          # recipe-sourced que depende de esta materia prima no puede
          # sincronizarse, todo esto se revierte junto — nunca queda un
          # unit_cost_cents nuevo sin que su costo haya terminado de propagarse.
          Costing::PropagateCostChange.call(raw_material)
        end
      end

      raw_material
    end

    private

    attr_reader :raw_material, :attributes, :changed_by

    def snapshot
      {
        purchase_price_cents: raw_material.purchase_price_cents,
        purchase_quantity: raw_material.purchase_quantity,
        purchase_unit: raw_material.purchase_unit,
        base_unit: raw_material.base_unit,
        unit_cost_cents: raw_material.unit_cost_cents
      }
    end
  end
end
