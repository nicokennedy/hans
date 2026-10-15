require "test_helper"

class Admin::CustomersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "customers-admin@example.com", password: "password123", role: "admin")
    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Ala Moana", active: true)
  end

  def build_order(customer, quantity: 2, delivery_date: Date.tomorrow, status: nil)
    order = Order.new(customer: customer, delivery_date: delivery_date)
    order.status = status if status
    order.order_items.build(product: @product, quantity: quantity)
    order.save!
    order
  end

  test "index shows the period summary and per-customer financial columns" do
    order = build_order(@customer, quantity: 2, delivery_date: Date.tomorrow) # total 1000
    order.payments.create!(amount_cents: 400, paid_at: Time.current, payment_method: "cash_on_delivery")

    sign_in @admin
    get admin_customers_path

    assert_response :success
    assert_match "Resumen del período", response.body
    assert_match "$10", response.body # facturado (1000 cents / 100)
    assert_match "$4", response.body # cobrado
    assert_select "td", text: "40%" # 400 paid / 1000 total
  end

  test "a customer with no invoicing in the period shows a dash instead of dividing by zero" do
    sign_in @admin
    get admin_customers_path, params: { period: "last_7_days" }

    assert_response :success
    # @customer has no orders at all, so its row should show "—" for percent
    assert_select "td", text: "—"
  end

  test "canceled orders are excluded from the customers index totals" do
    build_order(@customer, quantity: 2, delivery_date: Date.tomorrow) # total 1000, kept
    build_order(@customer, quantity: 10, delivery_date: Date.tomorrow, status: "canceled") # would add 5000 if counted

    sign_in @admin
    get admin_customers_path

    assert_response :success
    assert_match "$10", response.body
    assert_no_match "$60", response.body
  end

  test "changing the period filter persists across requests via session" do
    sign_in @admin

    get admin_customers_path, params: { period: "last_month" }
    assert_response :success
    assert_match "Mes anterior", response.body

    get admin_customers_path
    assert_response :success
    assert_match "Mes anterior", response.body
  end

  test "show displays the customer's own summary and its orders for the period" do
    order = build_order(@customer, quantity: 2, delivery_date: Date.tomorrow) # total 1000
    order.payments.create!(amount_cents: 1000, paid_at: Time.current, payment_method: "bank_transfer")

    sign_in @admin
    get admin_customer_path(@customer)

    assert_response :success
    assert_match @customer.name, response.body
    assert_match order.number, response.body
    assert_select ".badge", text: "Pagado"
  end

  test "show excludes canceled orders from the customer's own totals and list" do
    kept = build_order(@customer, quantity: 2, delivery_date: Date.tomorrow)
    canceled = build_order(@customer, quantity: 10, delivery_date: Date.tomorrow, status: "canceled")

    sign_in @admin
    get admin_customer_path(@customer)

    assert_response :success
    assert_match kept.number, response.body
    assert_no_match canceled.number, response.body
  end

  test "a non-admin cannot access the customers index or show" do
    regular_user = User.create!(email: "customers-regular@example.com", password: "password123", role: "customer", customer: @customer)
    sign_in regular_user

    get admin_customers_path
    assert_redirected_to dashboard_path

    get admin_customer_path(@customer)
    assert_redirected_to dashboard_path
  end

  test "an anonymous user cannot access the customers index or show" do
    get admin_customers_path
    assert_response :redirect

    get admin_customer_path(@customer)
    assert_response :redirect
  end

  test "the customers index runs a constant number of queries regardless of customer count" do
    sign_in @admin

    small_query_count = count_queries { get admin_customers_path }

    8.times do |n|
      customer = Customer.create!(name: "Cliente Extra #{n}", active: true)
      build_order(customer, quantity: 1, delivery_date: Date.tomorrow)
    end

    large_query_count = count_queries { get admin_customers_path }

    assert_equal small_query_count, large_query_count,
      "expected the same query count with 1 or 9 customers, got #{small_query_count} vs #{large_query_count} (possible N+1)"
  end

  test "the search finds customers by partial name ignoring case and accents" do
    Customer.create!(name: "Coco Olavarría", active: true)
    Customer.create!(name: "Café Gémez", active: true)

    sign_in @admin
    get admin_customers_path, params: { q: "olavarria" }

    assert_response :success
    assert_select "tbody td.fw-bold", count: 1
    assert_select "tbody td.fw-bold", text: "Coco Olavarría"
    assert_match "1 cliente encontrado", response.body

    get admin_customers_path, params: { q: "CAFE gem" }
    assert_select "tbody td.fw-bold", text: "Café Gémez"
    assert_select "tbody td.fw-bold", count: 1
  end

  test "the search also matches contact, commercial email, phone digits and access email" do
    Customer.create!(name: "Uno", contact_name: "Martín Pérez", active: true)
    Customer.create!(name: "Dos", email: "compras@dos.com.ar", active: true)
    Customer.create!(name: "Tres", phone: "+54 11 5512-3456", active: true)
    cuatro = Customer.create!(name: "Cuatro", active: true)
    User.create!(email: "portal@cuatro.com", password: "password123", role: "customer", customer: cuatro)

    sign_in @admin
    { "martin perez" => "Uno", "COMPRAS@DOS" => "Dos", "1155 123" => "Tres", "5512-34" => "Tres", "portal@cuatro" => "Cuatro" }.each do |query, name|
      get admin_customers_path, params: { q: query }
      assert_select "tbody td.fw-bold", { count: 1, text: name }, "#{query.inspect} should only find #{name}"
    end
  end

  test "the search runs over every customer and treats LIKE wildcards literally" do
    Customer.create!(name: "Cien % Natural", active: true)

    sign_in @admin
    get admin_customers_path, params: { q: "%" }
    assert_select "tbody td.fw-bold", count: 1
    assert_select "tbody td.fw-bold", text: "Cien % Natural"
  end

  test "a search without results shows a clear message and a way to clear it" do
    sign_in @admin
    get admin_customers_path, params: { q: "no existe" }

    assert_response :success
    assert_select "table", count: 0
    assert_select "#customers-empty", text: /No se encontraron clientes para «no existe»\./
    assert_select "a[href=?]", admin_customers_path, text: "Limpiar búsqueda"
    assert_select "#customer-search-input[value=?]", "no existe"
  end

  test "an empty search lists every customer and hides the clear button" do
    Customer.create!(name: "Otro", active: true)

    sign_in @admin
    get admin_customers_path, params: { q: "   " }

    assert_select "tbody td.fw-bold", count: 2
    assert_select "#customer-search a", text: "Limpiar", count: 0
  end

  test "each row opens the customer like Ver and the search travels to the detail and back" do
    sign_in @admin
    get admin_customers_path, params: { q: "ala" }

    detail = admin_customer_path(@customer, q: "ala")
    assert_select "tr.table-row-link[data-controller='row-link'][data-row-link-url-value=?]", detail
    assert_select "a[href=?]", detail, text: "Ver"
    assert_select "a[href=?]", edit_admin_customer_path(@customer, q: "ala"), text: "Editar"
    assert_select "form[action=?] input[name='q'][value='ala']", toggle_active_admin_customer_path(@customer)

    get detail
    assert_select "a[href=?]", admin_customers_path(q: "ala"), text: "← Clientes"
    assert_select "form input[type=hidden][name='q'][value='ala']"
  end

  test "toggling a customer keeps the current search" do
    sign_in @admin
    patch toggle_active_admin_customer_path(@customer), params: { q: "ala" }

    assert_redirected_to admin_customers_path(q: "ala")
    assert_not @customer.reload.active?
  end

  test "the period filter keeps the current search" do
    sign_in @admin
    get admin_customers_path, params: { q: "ala" }

    assert_select "form[action=?] input[type=hidden][name='q'][value='ala']", admin_customers_path
  end

  private

  def count_queries
    count = 0
    counter = ->(*, payload) do
      sql = payload[:sql].to_s
      count += 1 unless payload[:name] == "SCHEMA" || sql.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|RELEASE|SAVEPOINT)/i)
    end

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    count
  end
end
