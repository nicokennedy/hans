# Datos para los tests de Repartos (R2): clientes, pedidos mayoristas y un admin.
module DeliveryRouteHelpers
  def setup_delivery_data
    @admin = User.create!(email: "routes-admin-#{SecureRandom.hex(3)}@example.com", password: "password123", role: "admin")
    category = Category.create!(name: "Cat Repartos #{SecureRandom.hex(3)}", position: 1, active: true)
    @product = Product.create!(name: "Medialuna #{SecureRandom.hex(3)}", category: category, internal_category: "Facturas",
                               price_cents: 100_000, cost_cents: 30_000, active: true, position: 1)
    @date = next_delivery_date
    @driver = create_driver("Chiara")
  end

  def create_driver(name, active: true)
    User.create!(name: name, email: "#{name.parameterize}-#{SecureRandom.hex(3)}@example.com", password: "password123", role: "driver", active: active)
  end

  def create_customer(name, address: nil, **attrs)
    Customer.create!(name: name, address: address, active: true, **attrs)
  end

  def create_order(customer, date: @date, quantity: 2, status: nil)
    order = Order.new(customer: customer, delivery_date: date, created_by_admin: true)
    order.order_items.build(product: @product, quantity: quantity)
    order.save!
    order.update_column(:status, status) if status
    order
  end

  # --- R4 ---------------------------------------------------------------------------------

  def collections_for(route, user = @driver)
    DeliveryRoutes::Collections.new(route, user)
  end

  def collect(route, stop, cents, user: @driver, token: SecureRandom.uuid, allocations: nil, **opts)
    allocations ||= { stop.order_id => [cents, stop.order.reload.balance_due_cents].min }
    collections_for(route, user).record(stop: stop, amount_cents: cents, allocations: allocations, request_token: token, **opts)
  end

  def receipt_photo(name = "pixel.jpg")
    Rack::Test::UploadedFile.new(Rails.root.join("test/fixtures/files/retail_catalog", name), Marcel::MimeType.for(name: name))
  end

  def money_snapshot
    [Order.order(:id).pluck(:id, :status, :total_cents, :amount_paid_cents, :payment_status), StockMovement.count, Payment.individual.count, Expense.count]
  end

end
