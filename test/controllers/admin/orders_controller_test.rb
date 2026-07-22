require "test_helper"

class Admin::OrdersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "orders-admin@example.com", password: "password123", role: "admin")
    sign_in @admin

    @category = Category.create!(name: "Alfajores", position: 1, active: true)
    @product = Product.create!(name: "Alfajor Clásico", category: @category, price_cents: 300, cost_cents: 100, active: true, position: 1)
    @other_product = Product.create!(name: "Torta Brownie", category: @category, price_cents: 900, cost_cents: 500, active: true, position: 2)
    @customer = Customer.create!(name: "Cliente Test", active: true)

    @order = Order.create!(customer: @customer, delivery_date: Date.tomorrow)
    @item = @order.order_items.create!(product: @product, quantity: 2)
  end

  test "should get index" do
    get admin_orders_path
    assert_response :success
  end

  test "should get show" do
    get admin_order_path(@order)
    assert_response :success
  end

  test "changes the quantity of an existing line and recalculates totals" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: { @item.id => { quantity: "5" } }
    }

    assert_redirected_to admin_order_path(@order)
    assert_equal 5, @item.reload.quantity
    assert_equal 1500, @item.line_revenue_cents
    assert_equal 1500, @order.reload.total_cents
  end

  test "changes the product of an existing line and refreshes its snapshots" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: { @item.id => { product_id: @other_product.id, quantity: @item.quantity } }
    }

    assert_redirected_to admin_order_path(@order)
    @item.reload
    assert_equal @other_product.id, @item.product_id
    assert_equal @other_product.name, @item.product_name_snapshot
    assert_equal @other_product.category.name, @item.category_name_snapshot
    assert_equal @other_product.cost_cents, @item.unit_cost_cents_snapshot
    assert_equal 300, @item.unit_price_cents_snapshot
  end

  test "changes the unit price of an existing line without touching the catalog price" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: { @item.id => { quantity: @item.quantity, unit_price_amount: "250" } }
    }

    assert_redirected_to admin_order_path(@order)
    @item.reload
    assert_equal 25_000, @item.unit_price_cents_snapshot
    assert_equal 50_000, @item.line_revenue_cents
    assert_equal 300, @product.reload.price_cents
  end

  test "adds a new product line using the catalog price when none is given" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_product_id: @other_product.id,
      new_quantity: "3"
    }

    assert_redirected_to admin_order_path(@order)
    new_item = @order.reload.order_items.find_by(product_id: @other_product.id)
    assert_equal 3, new_item.quantity
    assert_equal @other_product.price_cents, new_item.unit_price_cents_snapshot
  end

  test "adds a new product line with a custom price when one is given" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_product_id: @other_product.id,
      new_quantity: "2",
      new_unit_price: "800"
    }

    assert_redirected_to admin_order_path(@order)
    new_item = @order.reload.order_items.find_by(product_id: @other_product.id)
    assert_equal 80_000, new_item.unit_price_cents_snapshot
  end

  test "merges a duplicated product into the existing line instead of creating a new one" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_product_id: @product.id,
      new_quantity: "4"
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 1, @order.order_items.where(product_id: @product.id).count
    assert_equal 6, @order.order_items.find_by(product_id: @product.id).quantity
  end

  test "removes a line item" do
    extra_item = @order.order_items.create!(product: @other_product, quantity: 1)

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: { extra_item.id => { remove: "1" } }
    }

    assert_redirected_to admin_order_path(@order)
    assert_not OrderItem.exists?(extra_item.id)
    assert_equal 1, @order.reload.order_items.count
  end

  test "does not allow removing the last remaining order item" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: { @item.id => { remove: "1" } }
    }

    assert_response :unprocessable_entity
    assert OrderItem.exists?(@item.id)
    assert_equal 1, @order.reload.order_items.count
  end

  test "recalculates the order total from quantity, removal and addition changes together" do
    extra_item = @order.order_items.create!(product: @other_product, quantity: 1)

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: {
        @item.id => { quantity: "3" },
        extra_item.id => { remove: "1" }
      },
      new_product_id: @other_product.id,
      new_quantity: "2"
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 2, @order.order_items.count
    assert_equal 3, @item.reload.quantity
    new_item = @order.order_items.find_by(product_id: @other_product.id)
    assert_equal 2, new_item.quantity
    assert_equal((3 * 300) + (2 * 900), @order.total_cents)
  end

  test "the edit form offers active products plus the line's own inactive product, but restricts new-product options to active ones" do
    inactive_product = Product.create!(name: "Descontinuado", category: @category, price_cents: 150, cost_cents: 60, active: false, position: 3)
    @item.update!(product: inactive_product)

    get edit_admin_order_path(@order)

    assert_response :success
    line_select_options = css_select("#order_items_#{@item.id}_product_id option").map(&:text)
    assert_includes line_select_options, inactive_product.name
    assert_includes line_select_options, @other_product.name

    new_product_options = css_select("#new_product_id option").map(&:text)
    assert_not_includes new_product_options, inactive_product.name
  end

  test "changing a line's product to one used by another line merges quantities, keeps the existing line's price, and removes the duplicate" do
    target = @order.order_items.create!(product: @other_product, quantity: 1, unit_price_amount: "700")

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: {
        @item.id => { product_id: @other_product.id, quantity: "3" },
        target.id => { quantity: target.quantity }
      }
    }

    assert_redirected_to admin_order_path(@order)
    assert_not OrderItem.exists?(@item.id)
    @order.reload
    assert_equal 1, @order.order_items.where(product_id: @other_product.id).count
    merged = @order.order_items.find_by(product_id: @other_product.id)
    assert_equal 1 + 3, merged.quantity
    assert_equal 70_000, merged.unit_price_cents_snapshot
  end

  test "merging into a target whose own quantity is edited in the same request adds on top of the new value" do
    target = @order.order_items.create!(product: @other_product, quantity: 1)

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      order_items: {
        @item.id => { product_id: @other_product.id, quantity: "3" },
        target.id => { quantity: "5" }
      }
    }

    assert_redirected_to admin_order_path(@order)
    merged = @order.reload.order_items.find_by(product_id: @other_product.id)
    assert_equal 5 + 3, merged.quantity
  end

  test "should get new" do
    get new_admin_order_path
    assert_response :success
  end

  test "index shows the Nuevo pedido button" do
    get admin_orders_path
    assert_response :success
    assert_select "a[href=?]", new_admin_order_path, text: "Nuevo pedido"
  end

  test "creates an order with a single item, saving unit_price_cents_snapshot and recalculating totals in the backend" do
    assert_difference ["Order.count", "OrderItem.count"], 1 do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending",
          payment_method_selected: "cash_on_delivery"
        },
        order_items: [
          { product_id: @product.id, quantity: "2", unit_price_amount: "500" }
        ]
      }
    end

    order = Order.order(:id).last
    assert_redirected_to admin_order_path(order)
    assert order.created_by_admin?
    assert_equal 1, order.order_items.count
    item = order.order_items.first
    assert_equal 50_000, item.unit_price_cents_snapshot
    assert_equal 100_000, item.line_revenue_cents
    assert_equal 100_000, order.total_cents
  end

  test "creates an order with several items and recalculates the combined total in the backend" do
    post admin_orders_path, params: {
      order: {
        customer_id: @customer.id,
        delivery_date: Date.tomorrow,
        status: "received",
        payment_status: "pending",
        payment_method_selected: "bank_transfer"
      },
      order_items: [
        { product_id: @product.id, quantity: "2", unit_price_amount: "3" },
        { product_id: @other_product.id, quantity: "1", unit_price_amount: "9" }
      ]
    }

    order = Order.order(:id).last
    assert_redirected_to admin_order_path(order)
    assert_equal 2, order.order_items.count
    assert_equal (2 * 300) + (1 * 900), order.total_cents
  end

  test "does not allow creating an order without any valid items" do
    assert_no_difference ["Order.count", "OrderItem.count"] do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending"
        },
        order_items: [
          { product_id: "", quantity: "1" }
        ]
      }
    end

    assert_response :unprocessable_entity
    assert_select ".alert-danger", text: /al menos un producto/
  end

  test "does not partially save the order when one of its items is invalid" do
    assert_no_difference ["Order.count", "OrderItem.count"] do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending"
        },
        order_items: [
          { product_id: @product.id, quantity: "2", unit_price_amount: "5" },
          { product_id: @other_product.id, quantity: "0", unit_price_amount: "9" }
        ]
      }
    end

    assert_response :unprocessable_entity
  end

  test "allows creating an order for a date that would be blocked for a regular customer" do
    blocked_date = next_sunday
    assert DeliveryDateValidator.reason(blocked_date).present?, "test setup expects this date to be blocked for customers"

    post admin_orders_path, params: {
      order: {
        customer_id: @customer.id,
        delivery_date: blocked_date,
        status: "received",
        payment_status: "pending"
      },
      order_items: [
        { product_id: @product.id, quantity: "1", unit_price_amount: "3" }
      ]
    }

    order = Order.order(:id).last
    assert_redirected_to admin_order_path(order)
    assert_equal blocked_date, order.delivery_date
  end

  test "a non-admin user cannot access new or create" do
    other_customer = Customer.create!(name: "Otro Cliente", active: true)
    regular_user = User.create!(email: "regular-user@example.com", password: "password123", role: "customer", customer: other_customer)
    sign_out @admin
    sign_in regular_user

    get new_admin_order_path
    assert_redirected_to dashboard_path

    assert_no_difference "Order.count" do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending"
        },
        order_items: [
          { product_id: @product.id, quantity: "1", unit_price_amount: "3" }
        ]
      }
    end

    assert_redirected_to dashboard_path
  end

  test "rejects a partially filled item row that has a price but no product selected" do
    assert_no_difference ["Order.count", "OrderItem.count"] do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending"
        },
        order_items: [
          { product_id: "", quantity: "1", unit_price_amount: "500" }
        ]
      }
    end

    assert_response :unprocessable_entity
    assert_select ".alert-danger", text: /sin producto seleccionado/
  end

  test "rejects a nonexistent product id with a clear error instead of crashing" do
    assert_no_difference ["Order.count", "OrderItem.count"] do
      post admin_orders_path, params: {
        order: {
          customer_id: @customer.id,
          delivery_date: Date.tomorrow,
          status: "received",
          payment_status: "pending"
        },
        order_items: [
          { product_id: "999999999", quantity: "1", unit_price_amount: "3" }
        ]
      }
    end

    assert_response :unprocessable_entity
    assert_select ".alert-danger", text: /ya no existe/
  end

  private

  def next_sunday
    date = Date.tomorrow
    date += 1 until date.wday == 0
    date
  end
end
