class AddCostSourceToProducts < ActiveRecord::Migration[7.1]
  def change
    # "manual" | "recipe" — quién gobierna Product#cost_cents. Default
    # "manual" así todos los productos existentes hoy (sin receta) quedan en
    # el mismo modo que ya tenían de hecho, sin cambiar ningún comportamiento.
    add_column :products, :cost_source, :string, null: false, default: "manual"
  end
end
