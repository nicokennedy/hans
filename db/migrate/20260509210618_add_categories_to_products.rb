class AddCategoriesToProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :products, :internal_category, :string
    add_column :products, :public_category, :string
  end
end
