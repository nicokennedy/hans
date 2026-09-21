class AddExceptionalAvailableDatesToDeliverySettings < ActiveRecord::Migration[7.1]
  def up
    add_column :delivery_settings, :exceptional_available_dates, :jsonb, default: [], null: false

    # Migra las fechas que hasta ahora vivían hardcodeadas en
    # DeliveryDateValidator::EXCEPTIONAL_AVAILABLE_DATES a la fila
    # persistida, para que 17/09/2026 y 22/09/2026 sigan disponibles sin
    # discontinuidad apenas se aplica este deploy. De acá en más, las
    # fechas excepcionales se administran desde Admin, no desde código.
    execute <<~SQL
      UPDATE delivery_settings
      SET exceptional_available_dates = '["2026-09-17","2026-09-22"]'::jsonb
    SQL
  end

  def down
    remove_column :delivery_settings, :exceptional_available_dates
  end
end
