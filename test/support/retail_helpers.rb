# Datos comunes de los tests del módulo de Pedidos Minoristas. Importes en centavos.
module RetailHelpers
  def setup_retail
    n = rand(1_000_000)
    @admin = User.create!(email: "retail-admin-#{n}@example.com", password: "password123", role: "admin")
    @category = Category.create!(name: "Retail #{n}", position: 1, active: true)
    @customer = Customer.create!(name: "Café Mayorista #{n}", active: true)
    @mini = make_product("Mini Rogel #{n}", 500)
    @torta = make_product("Torta #{n}", 4_000)
    @sunday = Date.new(2026, 10, 18) # domingo: no es día habitual de entrega mayorista
  end

  def make_product(name, price_cents)
    Product.create!(name: name, category: @category, price_cents: price_cents, cost_cents: 100, active: true, position: 1)
  end

  def pesos(amount)
    amount * 100
  end

  def base_attributes(overrides = {})
    { buyer_name: "María Pérez", buyer_phone: "11 5555-1234", delivery_date: @sunday.iso8601, delivery_kind: "pickup",
      delivery_time_note: "15:30", address: "", notes: "", planned_payment_method: "transfer", shipping: "" }.merge(overrides)
  end

  def product_row(product, quantity, price, **extra)
    { "kind" => "product", "product_id" => product.id.to_s, "quantity" => quantity.to_s, "unit_price" => price.to_s }.merge(extra.transform_keys(&:to_s))
  end

  def manual_row(description, quantity, price)
    { "kind" => "manual", "description" => description, "quantity" => quantity.to_s, "unit_price" => price.to_s }
  end

  def create_retail(attributes: {}, items: nil, user: @admin)
    items ||= [product_row(@mini, 12, "500")]
    result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(attributes), items: items, user: user)
    raise "no se pudo crear el pedido minorista: #{result.errors.inspect}" unless result.ok?

    result.record
  end

  def update_retail(order, attributes: {}, items:, user: @admin)
    result = Retail::SaveOrder.call(order: order, attributes: base_attributes(attributes), items: items, user: user)
    raise "no se pudo editar el pedido minorista: #{result.errors.inspect}" unless result.ok?

    result.record
  end

  def item_rows_for(order)
    order.retail_order_items.reload.map do |item|
      { "id" => item.id.to_s, "kind" => (item.catalog? ? "product" : "manual"), "product_id" => item.product_id.to_s, "description" => item.description,
        "quantity" => item.quantity.to_s, "unit_price" => (item.unit_price_cents / 100).to_s }
    end
  end

  def pay_retail(order, amount, method: "transfer", user: @admin, **opts)
    Retail::RegisterPayment.call(order: order, user: user, amount: amount, paid_at: Date.current, payment_method: method, **opts)
  end

  # Pedido mayorista (para probar la consolidación y la compatibilidad con stock).
  def wholesale_order(product, quantity, delivery_date, customer: @customer)
    order = Order.new(customer: customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: product, quantity: quantity)
    order.save!
    order
  end
end
