class AddDeliveryIncomeAndStopGroups < ActiveRecord::Migration[7.1]
  def change
    add_reference :delivery_stops, :group_leader, foreign_key: { to_table: :delivery_stops }
    add_column :delivery_routes, :other_income_cents, :bigint, default: 0, null: false

    create_table :delivery_incomes do |t|
      t.references :delivery_route, null: false, foreign_key: true
      t.references :created_by, null: false, foreign_key: { to_table: :users }
      t.references :voided_by, foreign_key: { to_table: :users }
      t.references :replaces, foreign_key: { to_table: :delivery_incomes }, index: { unique: true }
      t.string :kind, null: false
      t.string :description, null: false
      t.bigint :amount_cents, null: false
      t.string :request_token, null: false
      t.datetime :voided_at
      t.string :void_reason
      t.timestamps
      t.index [:delivery_route_id, :request_token], unique: true
      t.check_constraint "amount_cents > 0", name: "delivery_income_positive_amount"
    end
  end
end
