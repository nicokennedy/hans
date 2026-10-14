# Cliente habilitado para un producto restringido (Product#customer_visibility = "selected").
# Es solo permiso de PEDIR: no afecta recetas, costos, stock ni producción.
class ProductCustomerAccess < ApplicationRecord
  belongs_to :product
  belongs_to :customer

  validates :customer_id, uniqueness: { scope: :product_id }
end
