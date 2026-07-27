require "test_helper"

class Admin::ProductionControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "should get index" do
    get admin_production_index_url
    assert_response :success
  end

  test "show displays the WhatsApp button using the configured number, not the old hardcoded one" do
    admin = User.create!(email: "production-whatsapp-admin@example.com", password: "password123", role: "admin")
    category = Category.create!(name: "Alfajores", position: 1, active: true)
    product = Product.create!(name: "Alfajor Clásico", category: category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    customer = Customer.create!(name: "Cliente Test", active: true)
    order = Order.new(customer: customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: product, quantity: 2)
    order.save!

    sign_in admin

    with_whatsapp_number("5492235275412") do
      get admin_production_path(order.delivery_date)

      assert_response :success
      assert_match "wa.me/5492235275412", response.body
      assert_no_match "5492914168790", response.body
    end
  end

  test "show hides the WhatsApp button when WHATSAPP_OBRADOR_NUMBER is not configured" do
    admin = User.create!(email: "production-whatsapp-admin2@example.com", password: "password123", role: "admin")
    sign_in admin

    with_whatsapp_number(nil) do
      get admin_production_path(Date.tomorrow)

      assert_response :success
      assert_no_match "wa.me", response.body
      assert_match "no disponible", response.body
    end
  end

  test "the visible category column is gone, and products are sorted by internal_category then by name, both A-Z" do
    category = Category.create!(name: "Varios", position: 1, active: true)

    torta = Product.create!(name: "Torta de Chocolate", category: category, internal_category: "Tortas", price_cents: 500, cost_cents: 200, active: true, position: 1)
    alfajor = Product.create!(name: "Alfajor de Maicena", category: category, internal_category: "Tortas", price_cents: 300, cost_cents: 100, active: true, position: 2)
    pan = Product.create!(name: "Pan Lactal", category: category, internal_category: "Panificados", price_cents: 400, cost_cents: 150, active: true, position: 3)

    customer_uno = Customer.create!(name: "Café Uno", active: true)
    customer_dos = Customer.create!(name: "Café Dos", active: true)
    delivery_date = Date.tomorrow

    order1 = Order.new(customer: customer_uno, delivery_date: delivery_date)
    order1.order_items.build(product: torta, quantity: 3)
    order1.order_items.build(product: pan, quantity: 5)
    order1.save!

    order2 = Order.new(customer: customer_dos, delivery_date: delivery_date)
    order2.order_items.build(product: alfajor, quantity: 2)
    order2.order_items.build(product: pan, quantity: 4)
    order2.save!

    admin = User.create!(email: "production-order-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get admin_production_path(delivery_date)
    assert_response :success

    assert_no_match "Categoría", response.body
    assert_select "th", text: "Categoría", count: 0

    doc = Nokogiri::HTML::Document.parse(response.body)
    header_cells = doc.css("table.production-table thead th").map(&:text).map(&:strip)
    assert_equal [ "Producto", "TOTAL", "Café Dos", "Café Uno" ], header_cells

    product_names_in_order = doc.css("table.production-table tbody tr td:first-child").map(&:text).map(&:strip)
    assert_equal [ "Pan Lactal", "Alfajor de Maicena", "Torta de Chocolate" ], product_names_in_order

    rows_by_product = doc.css("table.production-table tbody tr").each_with_object({}) do |row, hash|
      cells = row.css("td").map { |cell| cell.text.strip }
      hash[cells[0]] = cells
    end

    pan_row = rows_by_product.fetch("Pan Lactal")
    assert_equal "9", pan_row[1] # TOTAL: 5 + 4
    assert_equal "4", pan_row[2] # Café Dos
    assert_equal "5", pan_row[3] # Café Uno

    alfajor_row = rows_by_product.fetch("Alfajor de Maicena")
    assert_equal "2", alfajor_row[1] # TOTAL
    assert_equal "2", alfajor_row[2] # Café Dos ordered it
    assert_equal "", alfajor_row[3]  # Café Uno did not order it: blank, not "0"

    torta_row = rows_by_product.fetch("Torta de Chocolate")
    assert_equal "3", torta_row[1] # TOTAL
    assert_equal "", torta_row[2]  # Café Dos did not order it: blank, not "0"
    assert_equal "3", torta_row[3] # Café Uno

    assert_no_match(/<td[^>]*>\s*0\s*<\/td>/, response.body)
  end

  test "customer names stay vertical and the table scrolls horizontally with many customers" do
    category = Category.create!(name: "Varios", position: 1, active: true)
    product = Product.create!(name: "Medialuna", category: category, internal_category: "Panificados", price_cents: 100, cost_cents: 40, active: true, position: 1)
    delivery_date = Date.tomorrow

    12.times do |i|
      customer = Customer.create!(name: "Café Número #{i}", active: true)
      order = Order.new(customer: customer, delivery_date: delivery_date)
      order.order_items.build(product: product, quantity: i + 1)
      order.save!
    end

    admin = User.create!(email: "production-manycustomers-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get admin_production_path(delivery_date)
    assert_response :success

    assert_select ".table-responsive"
    assert_select "th.vertical-column", count: 12
  end

  test "print and public_print respond successfully, drop the category column, keep the same order/totals/quantities as the interactive screen, and never show a literal 0" do
    category = Category.create!(name: "Varios", position: 1, active: true)

    torta = Product.create!(name: "Torta de Chocolate", category: category, internal_category: "Tortas", price_cents: 500, cost_cents: 200, active: true, position: 1)
    alfajor = Product.create!(name: "Alfajor de Maicena", category: category, internal_category: "Tortas", price_cents: 300, cost_cents: 100, active: true, position: 2)
    pan = Product.create!(name: "Pan Lactal", category: category, internal_category: "Panificados", price_cents: 400, cost_cents: 150, active: true, position: 3)

    customer_uno = Customer.create!(name: "Café Uno", active: true)
    customer_dos = Customer.create!(name: "Café Dos", active: true)
    delivery_date = Date.tomorrow

    order1 = Order.new(customer: customer_uno, delivery_date: delivery_date)
    order1.order_items.build(product: torta, quantity: 3)
    order1.order_items.build(product: pan, quantity: 5)
    order1.save!

    order2 = Order.new(customer: customer_dos, delivery_date: delivery_date)
    order2.order_items.build(product: alfajor, quantity: 2)
    order2.order_items.build(product: pan, quantity: 4)
    order2.save!

    admin = User.create!(email: "production-print-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get admin_production_path(delivery_date)
    assert_response :success
    screen_doc = Nokogiri::HTML::Document.parse(response.body)
    screen_rows = screen_doc.css("table.production-table tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }

    get print_admin_production_path(delivery_date)
    assert_response :success
    assert_no_match "Categoría", response.body
    assert_select ".category-col", count: 0
    print_doc = Nokogiri::HTML::Document.parse(response.body)
    print_rows = print_doc.css("table tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }

    assert_equal screen_rows, print_rows
    assert_no_match(/<td[^>]*>\s*0\s*<\/td>/, response.body)

    get public_production_print_path(delivery_date)
    assert_response :success
    assert_no_match "Categoría", response.body
    public_doc = Nokogiri::HTML::Document.parse(response.body)
    public_rows = public_doc.css("table tbody tr").map { |row| row.css("td").map { |cell| cell.text.strip } }
    assert_equal screen_rows, public_rows
    assert_no_match(/<td[^>]*>\s*0\s*<\/td>/, response.body)
  end

  test "print keeps customer names vertical and centered, with visible cell borders" do
    category = Category.create!(name: "Varios", position: 1, active: true)
    product = Product.create!(name: "Medialuna", category: category, internal_category: "Panificados", price_cents: 100, cost_cents: 40, active: true, position: 1)
    delivery_date = Date.tomorrow

    customer = Customer.create!(name: "Café Con Un Nombre Bastante Largo Para Probar", active: true)
    order = Order.new(customer: customer, delivery_date: delivery_date)
    order.order_items.build(product: product, quantity: 2)
    order.save!

    admin = User.create!(email: "production-print-vertical-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get print_admin_production_path(delivery_date)
    assert_response :success

    assert_match(/writing-mode:\s*vertical-rl/, response.body)
    assert_match(/vertical-align:\s*middle/, response.body)
    assert_match(/th,\s*\n?\s*td\s*\{[^}]*border:\s*1px solid/m, response.body)
    assert_select ".customer-header", count: 1
  end

  test "print works with many customers and long names without breaking the table" do
    category = Category.create!(name: "Varios", position: 1, active: true)
    product = Product.create!(name: "Medialuna", category: category, internal_category: "Panificados", price_cents: 100, cost_cents: 40, active: true, position: 1)
    delivery_date = Date.tomorrow

    12.times do |i|
      customer = Customer.create!(name: "Café Con Nombre Bastante Largo Numero #{i}", active: true)
      order = Order.new(customer: customer, delivery_date: delivery_date)
      order.order_items.build(product: product, quantity: i + 1)
      order.save!
    end

    admin = User.create!(email: "production-print-many-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get print_admin_production_path(delivery_date)
    assert_response :success
    assert_select ".customer-header", count: 12
  end

  private

  def with_whatsapp_number(value)
    original = ENV["WHATSAPP_OBRADOR_NUMBER"]
    ENV["WHATSAPP_OBRADOR_NUMBER"] = value
    yield
  ensure
    ENV["WHATSAPP_OBRADOR_NUMBER"] = original
  end
end
