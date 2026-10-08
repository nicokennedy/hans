# Datos comunes de los tests de cuenta corriente. Importes en centavos; el producto
# cuesta $1.000, así que `quantity` = miles de pesos del pedido.
module CustomerAccountHelpers
  def setup_account
    @admin = User.create!(email: "acct-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @category = Category.create!(name: "AcctCat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Producto Acct #{rand(1_000_000)}", category: @category, price_cents: 100_000, cost_cents: 50_000, active: true, position: 1)
    @customer = Customer.create!(name: "Honey #{rand(1_000_000)}", active: true)
    @other_customer = Customer.create!(name: "Otro #{rand(1_000_000)}", active: true)
  end

  def pesos(amount)
    amount * 100
  end

  # Pedido de `thousands` miles de pesos (total = thousands * $1.000).
  def make_order(thousands, customer: @customer, delivery_date: Date.new(2026, 10, 12), status: nil)
    order = Order.new(customer: customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "bank_transfer")
    order.status = status if status
    order.order_items.build(product: @product, quantity: thousands)
    order.save!
    order.reload
  end

  def register(amount_pesos, allocations: nil, customer: @customer, orders: nil, paid_on: Date.current, method: "bank_transfer", token: nil, reference: nil, note: nil, user: @admin)
    orders ||= CustomerAccounts::Distribution.pending_orders(customer).to_a
    allocations ||= CustomerAccounts::Distribution.suggest(orders, pesos(amount_pesos)).allocations
    CustomerAccounts::RegisterPayment.call(customer: customer, user: user, amount_cents: pesos(amount_pesos), paid_on: paid_on, payment_method: method,
                                           allocations: allocations, reference: reference, note: note, request_token: token)
  end

  # Honey: $120.000 + $95.000 + $180.000 del enunciado.
  def honey_orders
    [make_order(120, delivery_date: Date.new(2026, 10, 5)), make_order(95, delivery_date: Date.new(2026, 10, 6)), make_order(180, delivery_date: Date.new(2026, 10, 7))]
  end

  def balances(*orders)
    orders.map { |o| o.reload.balance_due_cents }
  end
end
