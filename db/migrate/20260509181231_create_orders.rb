class CreateOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :orders do |t|
      t.string :number
      t.references :customer, null: false, foreign_key: true
      t.date :delivery_date
      t.string :status
      t.string :payment_method_selected
      t.string :payment_status
      t.integer :amount_paid_cents
      t.datetime :paid_at
      t.text :customer_comment
      t.text :internal_note
      t.integer :total_cents
      t.boolean :created_by_admin

      t.timestamps
    end
  end
end
