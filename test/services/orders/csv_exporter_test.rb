require "test_helper"

class Orders::CsvExporterTest < ActiveSupport::TestCase
  def setup
    @category = Category.create!(name: "CsvExporterCat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Croissant CsvExporter", category: @category, price_cents: 50000, cost_cents: 20000, active: true, position: 1)
    @other_product = Product.create!(name: "Scon CsvExporter", category: @category, price_cents: 10000, cost_cents: 4000, active: true, position: 2)
    @customer = Customer.create!(name: "Cliente CsvExporter #{rand(1_000_000)}", active: true)
    @admin = User.create!(email: "csvexporter-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
  end

  def build_order(delivery_date: Date.tomorrow)
    order = Order.new(customer: @customer, delivery_date: delivery_date, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: 1)
    order.save!
    order
  end

  def parsed_rows(order)
    csv_text = Orders::CsvExporter.new([ order ]).call
    csv_text = csv_text.delete_prefix(Orders::CsvExporter::BOM)
    CSV.parse(csv_text, headers: true)
  end

  test "an order with no payments is Pendiente, paid 0, balance equal to the total" do
    order = build_order

    row = parsed_rows(order).first

    assert_equal "Pendiente", row["Estado de pago"]
    assert_equal "0.00", row["Total pagado"]
    assert_equal format("%.2f", order.total_cents / 100.0), row["Saldo pendiente"]
  end

  test "a partially paid order is Parcial, with the paid amount and the remaining balance" do
    order = build_order
    order.payments.create!(amount: (order.total_cents / 100 / 2), paid_at: Time.current, payment_method: "cash_on_delivery")
    order.reload

    row = parsed_rows(order).first

    assert_equal "Parcial", row["Estado de pago"]
    assert_equal format("%.2f", order.amount_paid_cents / 100.0), row["Total pagado"]
    assert_equal format("%.2f", order.balance_due_cents / 100.0), row["Saldo pendiente"]
    assert_not_equal "0.00", row["Saldo pendiente"]
  end

  test "a fully paid order is Pagado, with the full total paid and zero balance" do
    order = build_order
    order.payments.create!(amount: (order.total_cents / 100), paid_at: Time.current, payment_method: "bank_transfer")
    order.reload

    row = parsed_rows(order).first

    assert_equal "Pagado", row["Estado de pago"]
    assert_equal format("%.2f", order.total_cents / 100.0), row["Total pagado"]
    assert_equal "0.00", row["Saldo pendiente"]
  end

  test "an order with several products repeats the same payment columns on every row" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow, created_by_admin: true, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: 2)
    order.order_items.build(product: @other_product, quantity: 3)
    order.save!
    order.payments.create!(amount: (order.total_cents / 100), paid_at: Time.current, payment_method: "cash_on_delivery")
    order.reload

    rows = parsed_rows(order)

    assert_equal 2, rows.size
    rows.each do |row|
      assert_equal "Pagado", row["Estado de pago"]
      assert_equal format("%.2f", order.total_cents / 100.0), row["Total pagado"]
      assert_equal "0.00", row["Saldo pendiente"]
    end
    assert_equal [ "Croissant CsvExporter", "Scon CsvExporter" ], rows.map { |r| r["Producto"] }
  end

  test "the header row ends with Estado de pago, Total pagado, Saldo pendiente" do
    order = build_order

    csv_text = Orders::CsvExporter.new([ order ]).call.delete_prefix(Orders::CsvExporter::BOM)
    headers = CSV.parse(csv_text, headers: true).headers

    assert_equal [ "Estado de pago", "Total pagado", "Saldo pendiente" ], headers.last(3)
  end
end
