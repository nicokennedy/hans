class AddStockTrackingStartedOnToStockItems < ActiveRecord::Migration[7.1]
  def up
    # Fecha de entrega desde la cual el StockItem participa del control: los
    # pedidos con delivery_date anterior se ignoran (no comprometen ni
    # descuentan). Es un dato explícito, no se deriva de created_at.
    add_column :stock_items, :stock_tracking_started_on, :date

    # Solo para filas ya existentes: arrancan el día (hora Argentina) en que
    # se crearon. De acá en adelante nadie depende de created_at.
    execute <<~SQL
      UPDATE stock_items
      SET stock_tracking_started_on = (created_at AT TIME ZONE 'UTC' AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    SQL

    change_column_null :stock_items, :stock_tracking_started_on, false
  end

  def down
    remove_column :stock_items, :stock_tracking_started_on
  end
end
