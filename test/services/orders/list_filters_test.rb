require "test_helper"

class Orders::ListFiltersTest < ActiveSupport::TestCase
  def setup
    @customer = Customer.create!(name: "LF Cliente #{rand(1_000_000)}", active: true)
  end

  def filters(params = {}, **options)
    Orders::ListFilters.new(params, **options)
  end

  test "sin params: todo por defecto y query vacía" do
    f = filters
    assert_nil f.customer_id
    assert_nil f.delivery_date
    assert_equal "all", f.payment_status
    assert_equal 1, f.page
    assert_not f.active?
    assert_equal({}, f.to_query)
  end

  test "normaliza valores válidos y arma una query canónica" do
    f = filters({ customer_id: @customer.id.to_s, delivery_date: "2026-10-09", payment_status_filter: "pending", page: "3" })

    assert_equal @customer.id, f.customer_id
    assert_equal Date.new(2026, 10, 9), f.delivery_date
    assert_equal "pending", f.payment_status
    assert f.active?
    assert_equal({ customer_id: @customer.id, delivery_date: "2026-10-09", payment_status_filter: "pending", page: 3 }, f.to_query)
  end

  test "ignora lo inválido o manipulado" do
    f = filters({ customer_id: "999999999", delivery_date: "xx", payment_status_filter: "hack", page: "-1" })

    assert_nil f.customer_id
    assert_nil f.delivery_date
    assert f.invalid_date
    assert_equal "all", f.payment_status
    assert_equal 1, f.page
    assert_equal({}, f.to_query)
  end

  test "arrays, hashes y strings raros no pasan" do
    assert_nil filters({ customer_id: [@customer.id.to_s] }).customer_id
    assert_nil filters({ customer_id: "#{@customer.id} OR 1=1" }).customer_id
    assert_nil filters({ customer_id: "-#{@customer.id}" }).customer_id
    assert_nil filters({ delivery_date: ["2026-10-09"] }).delivery_date
  end

  test "quien no ve pagos nunca filtra por estado de pago, ni por el fallback de la sesión" do
    f = filters({ payment_status_filter: "paid" }, payment_fallback: "pending", allow_payment: false)
    assert_equal "all", f.payment_status
    assert_equal({}, f.to_query)
  end

  test "sin param de pago usa el filtro guardado (compatibilidad con la sesión)" do
    assert_equal "paid", filters({}, payment_fallback: "paid").payment_status
    assert_equal "pending", filters({ payment_status_filter: "pending" }, payment_fallback: "paid").payment_status
    assert_equal "all", filters({}, payment_fallback: "basura").payment_status
  end

  test "pagina de a 50 y acota la página pedida" do
    category = Category.create!(name: "LFCat#{rand(1_000_000)}", position: 1, active: true)
    product = Product.create!(name: "LF Prod #{rand(1_000_000)}", category: category, price_cents: 100, cost_cents: 50, active: true, position: 1)
    120.times do
      order = Order.new(customer: @customer, delivery_date: Date.new(2026, 10, 9), created_by_admin: true)
      order.order_items.build(product: product, quantity: 1)
      order.save!
    end

    f = filters({ page: "2" })
    page = f.paginate(Order.where(customer: @customer).order(:id))
    assert_equal 50, page.to_a.size
    assert_equal 3, f.total_pages
    assert_equal 2, f.page
    assert_equal 120, f.total_count

    last = filters({ page: "999" })
    assert_equal 20, last.paginate(Order.where(customer: @customer).order(:id)).to_a.size
    assert_equal 3, last.page
    assert_equal 3, last.to_query[:page]
  end
end
