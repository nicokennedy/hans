class CreateOrderEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :order_events do |t|
      t.references :order, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.string :event_type
      t.string :field_name
      t.text :old_value
      t.text :new_value
      t.text :reason

      t.timestamps
    end
  end
end
