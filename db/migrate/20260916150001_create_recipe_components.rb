class CreateRecipeComponents < ActiveRecord::Migration[7.1]
  def change
    # Sin FK reales (no es posible con polimorfismo apuntando a dos tablas
    # distintas) — la integridad se protege a nivel modelo: inclusion en
    # owner_type/component_type, y RawMaterial/Preparation con
    # dependent: :restrict_with_error en el lado "component".
    create_table :recipe_components do |t|
      t.string :owner_type, null: false
      t.bigint :owner_id, null: false
      t.string :component_type, null: false
      t.bigint :component_id, null: false

      t.decimal :quantity, precision: 12, scale: 3, null: false
      t.string :unit, null: false
      t.integer :position

      t.timestamps
    end

    add_index :recipe_components, [ :owner_type, :owner_id ], name: "index_recipe_components_on_owner"
    add_index :recipe_components, [ :component_type, :component_id ], name: "index_recipe_components_on_component"
  end
end
