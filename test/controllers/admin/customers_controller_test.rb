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
