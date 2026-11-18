# Datos de entrega de los clientes mayoristas (Repartos). Solo columnas opcionales, sin valores
# por defecto ni índices: los clientes existentes no cambian y en Postgres no se reescribe la
# tabla. `address` sigue siendo "calle y número". Se completan con el Excel de
# Administración → Clientes (ver docs/CLIENTES_DIRECCIONES.md).
class AddDeliveryAddressFieldsToCustomers < ActiveRecord::Migration[7.1]
  def change
    add_column :customers, :address_unit, :string          # Piso / depto / local
    add_column :customers, :city, :string                  # Localidad
    add_column :customers, :province, :string              # Provincia
    add_column :customers, :postal_code, :string           # Código postal
    add_column :customers, :delivery_instructions, :text   # Referencias de entrega
  end
end
