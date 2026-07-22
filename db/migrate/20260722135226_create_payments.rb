class CreatePayments < ActiveRecord::Migration[7.1]
  def change
    create_table :payments do |t|
      t.references :order, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.datetime :paid_at, null: false
      t.string :payment_method, null: false
      t.text :note

      t.timestamps
    end

    add_index :payments, :paid_at
  end
end
