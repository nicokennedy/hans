class CreateDeliverySettings < ActiveRecord::Migration[7.1]
  def change
    create_table :delivery_settings do |t|
      t.integer :cutoff_hour
      t.jsonb :unavailable_weekdays

      t.timestamps
    end
  end
end
