class CreateProducts < ActiveRecord::Migration[7.1]
  def change
    create_table :products do |t|
      t.string :name
      t.text :description
      t.integer :price_cents
      t.integer :cost_cents
      t.references :category, null: false, foreign_key: true
      t.boolean :active
      t.integer :position
      t.string :unit

      t.timestamps
    end
  end
end
