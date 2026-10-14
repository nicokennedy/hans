# Datos comunes de los tests de visibilidad de productos por cliente.
module VisibilityHelpers
  # Lunes 5/10/2026 10:00: "hoy" fijo para que las fechas de entrega mayoristas sean válidas.
  def setup_visibility
    travel_to Time.zone.local(2026, 10, 5, 10, 0, 0)
    n = rand(1_000_000)
    @category = Category.create!(name: "Vis #{n}", position: 1, active: true)
    @cafe_a = Customer.create!(name: "Café A #{n}", active: true)
    @cafe_b = Customer.create!(name: "Café B #{n}", active: true)
    @cafe_c = Customer.create!(name: "Café C #{n}", active: true)
    @user_a = User.create!(email: "vis-a-#{n}@example.com", password: "password123", role: "customer", customer: @cafe_a)
    @user_b = User.create!(email: "vis-b-#{n}@example.com", password: "password123", role: "customer", customer: @cafe_b)
    @admin = User.create!(email: "vis-admin-#{n}@example.com", password: "password123", role: "admin")
    @rogel = make_product("Mini Rogel #{n}", 500)
    @exclusive_a = make_product("Exclusivo A #{n}", 900, customers: [@cafe_a])
    @special_abc = make_product("Especial ABC #{n}", 700, customers: [@cafe_a, @cafe_b, @cafe_c])
    @delivery = Date.new(2026, 10, 7)
  end

  def make_product(name, price_cents, customers: nil, **attrs)
    product = Product.new({ name: name, category: @category, price_cents: price_cents, cost_cents: 100, active: true, position: 1 }.merge(attrs))
    if customers
      product.customer_visibility = "selected_customers"
      product.authorized_customers = customers
    end
    product.save!
    product
  end

  def wholesale_order_for(customer, items, delivery_date: @delivery, created_by_admin: false)
    order = Order.new(customer: customer, delivery_date: delivery_date, created_by_admin: created_by_admin)
    items.each { |product, quantity| order.order_items.build(product: product, quantity: quantity) }
    order.save!
    order
  end
end
