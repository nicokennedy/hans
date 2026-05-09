class CreateCustomers < ActiveRecord::Migration[7.1]
  def change
    create_table :customers do |t|
      t.string :name
      t.string :contact_name
      t.string :email
      t.string :phone
      t.string :address
      t.string :payment_terms
      t.text :internal_notes
      t.boolean :active

      t.timestamps
    end
  end
end
