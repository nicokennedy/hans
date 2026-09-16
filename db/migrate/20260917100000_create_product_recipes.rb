class CreateProductRecipes < ActiveRecord::Migration[7.1]
  def change
    # A diferencia de RecipeComponent, esta belongs_to NO es polimórfica —
    # apunta siempre a products, así que sí hay FK real + índice único
    # (como máximo una ProductRecipe por Product, reforzado también en el
    # modelo con una validación de unicidad).
    create_table :product_recipes do |t|
      t.bigint :product_id, null: false
      t.decimal :yield_quantity, precision: 12, scale: 3, null: false

      t.timestamps
    end

    add_index :product_recipes, :product_id, unique: true
    add_foreign_key :product_recipes, :products
  end
end
