# Una fila de `payments` sigue siendo "lo pagado a un pedido": toda la lógica de
# saldos y estados de pago (Order#recalculate_payment_state!) sigue leyendo de ahí.
# Las columnas nuevas son todas NULL para los pagos existentes, que quedan
# exactamente como están (pagos individuales por pedido):
#   customer_payment_id : si viene de un pago de cuenta corriente (aplicación)
#   application_kind    : "distribution" (al registrar el pago) | "credit" (saldo a favor aplicado después)
#   user_id             : quién lo registró (los históricos no lo tienen)
#   voided_*            : anulación sin borrar el registro (no cuenta en el saldo del pedido)
class AddCustomerPaymentFieldsToPayments < ActiveRecord::Migration[7.1]
  def change
    add_reference :payments, :customer_payment, foreign_key: true
    add_column :payments, :application_kind, :string
    add_reference :payments, :user, foreign_key: true
    add_column :payments, :voided_at, :datetime
    add_column :payments, :void_reason, :text
    add_index :payments, :voided_at
  end
end
