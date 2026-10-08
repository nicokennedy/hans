require "test_helper"
require_relative "../../support/customer_account_helpers"

# Con transacciones reales en hilos distintos (los tests transaccionales no sirven acá):
# cada prueba limpia lo que crea.
class CustomerAccounts::ConcurrencyTest < ActiveSupport::TestCase
  include CustomerAccountHelpers

  self.use_transactional_tests = false

  def setup
    setup_account
    @created = { orders: [], customers: [@customer, @other_customer] }
  end

  def teardown
    ids = Order.where(customer_id: [@customer.id, @other_customer.id]).pluck(:id)
    Payment.where(order_id: ids).delete_all
    CustomerPayment.where(customer_id: [@customer.id, @other_customer.id]).delete_all
    OrderItem.where(order_id: ids).delete_all
    OrderEvent.where(order_id: ids).delete_all
    StockMovement.where(order_id: ids).delete_all
    Order.where(id: ids).delete_all
    Customer.where(id: [@customer.id, @other_customer.id]).delete_all
    @product.destroy
    @category.destroy
    @admin.destroy
  end

  def in_threads(count)
    barrier = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.pop
          yield i
        end
      end
    end
    count.times { barrier << true }
    threads.map(&:value)
  end

  test "dos pagos globales simultáneos por el mismo saldo: solo uno se aplica y nunca se excede" do
    order = make_order(100)

    results = in_threads(2) do |i|
      register(100_000, orders: [], allocations: { order.id => pesos(100_000) }, token: "t#{i}-#{SecureRandom.hex(4)}")
    end

    assert_equal 1, results.count(&:ok?), "exactamente uno gana: #{results.map(&:errors).inspect}"
    assert_equal pesos(100_000), order.reload.amount_paid_cents
    assert_equal 0, order.balance_due_cents
    assert_equal 1, Payment.where(order_id: order.id).count
    assert_equal 1, CustomerPayment.where(customer_id: @customer.id).count
  end

  test "un pago global y un pago individual simultáneos no exceden el saldo del pedido" do
    order = make_order(100)

    results = in_threads(2) do |i|
      if i.zero?
        register(100_000, orders: [], allocations: { order.id => pesos(100_000) }, token: SecureRandom.hex(4)).ok?
      else
        Order.find(order.id).with_lock { Payment.new(order_id: order.id, amount_cents: pesos(100_000), paid_at: Time.current, payment_method: "cash_on_delivery").save }
      end
    end

    assert_equal 1, results.count(true), "solo uno de los dos pagos entra"
    assert_equal pesos(100_000), order.reload.amount_paid_cents
    assert_operator order.amount_paid_cents, :<=, order.total_cents
  end

  test "el mismo formulario reenviado a la vez (mismo token) registra un solo pago" do
    order = make_order(100)
    token = SecureRandom.uuid

    results = in_threads(3) { register(40_000, orders: [], allocations: { order.id => pesos(40_000) }, token: token) }

    assert results.all?(&:ok?)
    assert_equal 1, results.count { |r| !r.duplicate? }
    assert_equal 1, CustomerPayment.where(customer_id: @customer.id).count
    assert_equal pesos(40_000), order.reload.amount_paid_cents
  end

  test "dos aplicaciones simultáneas del mismo saldo a favor no lo usan dos veces" do
    register(50_000, orders: [], allocations: {})
    a = make_order(50)
    b = make_order(50)

    results = in_threads(2) do |i|
      CustomerAccounts::ApplyCredit.call(customer: @customer, user: @admin, allocations: { (i.zero? ? a : b).id => pesos(50_000) })
    end

    assert_equal 1, results.count(&:ok?)
    assert_equal pesos(50_000), Payment.active.where(order_id: [a.id, b.id]).sum(:amount_cents)
    assert_equal 0, CustomerAccounts::ApplyCredit.available_cents(@customer)
  end
end
