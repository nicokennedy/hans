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
      new_order_items: [ { product_id: @other_product.id, quantity: "3" } ]
    }

    assert_redirected_to admin_order_path(@order)
    new_item = @order.reload.order_items.find_by(product_id: @other_product.id)
    assert_equal 3, new_item.quantity
    assert_equal @other_product.price_cents, new_item.unit_price_cents_snapshot
  end

  test "adds a new product line with a custom price when one is given" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [ { product_id: @other_product.id, quantity: "2", unit_price_amount: "800" } ]
    }

    assert_redirected_to admin_order_path(@order)
    new_item = @order.reload.order_items.find_by(product_id: @other_product.id)
    assert_equal 80_000, new_item.unit_price_cents_snapshot
  end

  test "merges a duplicated product into the existing line instead of creating a new one" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [ { product_id: @product.id, quantity: "4" } ]
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal 1, @order.order_items.where(product_id: @product.id).count
    assert_equal 6, @order.order_items.find_by(product_id: @product.id).quantity
  end

  test "adds several new product lines in the same edit, each one persisted correctly" do
    third_product = Product.create!(name: "Cookie Chispas", category: @category, price_cents: 250, cost_cents: 90, active: true, position: 3)

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [
        { product_id: @other_product.id, quantity: "2" },
        { product_id: third_product.id, quantity: "5", unit_price_amount: "300" }
      ]
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    other_item = @order.order_items.find_by(product_id: @other_product.id)
    third_item = @order.order_items.find_by(product_id: third_product.id)

    assert_equal 2, other_item.quantity
    assert_equal @other_product.price_cents, other_item.unit_price_cents_snapshot
    assert_equal 5, third_item.quantity
    assert_equal 30_000, third_item.unit_price_cents_snapshot
  end

  test "adding several new lines merges any that repeat a product already in the order or among themselves" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [
        { product_id: @product.id, quantity: "1" }, # repeats @item's product (already in the order)
        { product_id: @other_product.id, quantity: "2" },
        { product_id: @other_product.id, quantity: "3" } # repeats the new line above
      ]
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload

    assert_equal 1, @order.order_items.where(product_id: @product.id).count
    assert_equal 3, @order.order_items.find_by(product_id: @product.id).quantity # 2 (original) + 1

    assert_equal 1, @order.order_items.where(product_id: @other_product.id).count
    assert_equal 5, @order.order_items.find_by(product_id: @other_product.id).quantity # 2 + 3
  end

  test "existing lines are left untouched (historical price preserved) when only adding new lines" do
    original_snapshot = @item.unit_price_cents_snapshot

    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [ { product_id: @other_product.id, quantity: "1" } ]
    }

    assert_redirected_to admin_order_path(@order)
    assert_equal original_snapshot, @item.reload.unit_price_cents_snapshot
    assert_equal 2, @item.quantity
  end

  test "the total is recalculated correctly after adding new lines while editing" do
    patch admin_order_path(@order), params: {
      order: { delivery_date: @order.delivery_date, status: @order.status },
      new_order_items: [ { product_id: @other_product.id, quantity: "2" } ]
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    # @item: 2 x 300 = 600 ; new line: 2 x 900 = 1800
    assert_equal 2400, @order.total_cents
  end

  test "a blank new-line row (no product selected) is silently discarded, not an error" do
    assert_no_difference "OrderItem.count" do
      patch admin_order_path(@order), params: {
        order: { delivery_date: @order.delivery_date, status: @order.status },
        new_order_items: [ { product_id: "", quantity: "1" } ]
      }
    end

    assert_redirected_to admin_order_path(@order)
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

  test "new-order form preloads each product's list price as a data attribute for the JS auto-fill" do
    get new_admin_order_path

    assert_response :success
    assert_select "select.form-select-sm option[value=?]", @product.id.to_s do |options|
      assert_equal @product.price_amount.to_s, options.first["data-price-amount"]
    end
    assert_select "select.form-select-sm option[value=?]", @other_product.id.to_s do |options|
      assert_equal @other_product.price_amount.to_s, options.first["data-price-amount"]
    end
  end

  test "new-order form offers Efectivo contraentrega as a payment method" do
    get new_admin_order_path

    assert_response :success
    assert_select "select#order_payment_method_selected option", text: "Efectivo contraentrega"
  end

  test "edit form offers Agregar otra línea, price auto-fill data, and Efectivo contraentrega" do
    get edit_admin_order_path(@order)

    assert_response :success
    assert_select "button[data-action=?]", "order-items#add", text: "Agregar otra línea"
    assert_select "template" # holds the new-line partial for the Stimulus controller to clone
    assert_select "select#order_payment_method_selected option", text: "Efectivo contraentrega"
    assert_select "select.form-select-sm option[value=?]", @other_product.id.to_s do |options|
      assert_equal @other_product.price_amount.to_s, options.first["data-price-amount"]
    end
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

  test "allows creating orders for Tuesday and Thursday, both blocked for a regular customer" do
    [ next_weekday(2), next_weekday(4) ].each do |blocked_date|
      assert DeliveryDateValidator.reason(blocked_date).present?, "test setup expects #{blocked_date} to be blocked for customers"

      assert_difference "Order.count", 1 do
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
      end

      order = Order.order(:id).last
      assert_redirected_to admin_order_path(order)
      assert_equal blocked_date, order.delivery_date
    end
  end

  test "allows editing an existing order to move its delivery date to Tuesday, Thursday or Sunday" do
    [ next_weekday(2), next_weekday(4), next_weekday(0) ].each do |blocked_date|
      patch admin_order_path(@order), params: {
        order: { delivery_date: blocked_date, status: @order.status }
      }

      assert_redirected_to admin_order_path(@order)
      assert_equal blocked_date, @order.reload.delivery_date
    end
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

  test "index shows a payment status badge and the pending balance on each card" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 2) # total 600
    order.save!
    order.payments.create!(amount_cents: 200, paid_at: Time.current, payment_method: "cash_on_delivery")

    get admin_orders_path

    assert_response :success
    assert_select ".badge", text: "Pago parcial"
    assert_match "Saldo: $4", response.body
  end

  test "the payment status filter shows only orders matching the selected status" do
    paid_order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    paid_order.order_items.build(product: @product, quantity: 1) # total 300
    paid_order.save!
    paid_order.payments.create!(amount_cents: 300, paid_at: Time.current, payment_method: "cash_on_delivery")

    pending_order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    pending_order.order_items.build(product: @product, quantity: 1)
    pending_order.save!

    get admin_orders_path, params: { payment_status_filter: "paid" }

    assert_response :success
    assert_match paid_order.number, response.body
    assert_no_match pending_order.number, response.body
  end

  test "the payment status filter persists across requests, including after visiting an order" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)
    order.save!

    get admin_orders_path, params: { payment_status_filter: "pending" }
    assert_response :success

    get admin_order_path(@order) # simulate navigating away
    assert_response :success

    get admin_orders_path
    assert_response :success
    assert_match order.number, response.body
  end

  test "show displays a WhatsApp button pointing to the configured number with the full order message" do
    with_whatsapp_number("5492235275412") do
      get admin_order_path(@order)

      assert_response :success
      assert_select "a", text: "Enviar pedido por WhatsApp"
      assert_match "wa.me/5492235275412", response.body
      assert_no_match "5492914168790", response.body
      assert_match ERB::Util.url_encode("Cliente: #{@customer.name}"), response.body
    end
  end

  test "show hides the WhatsApp button when WHATSAPP_OBRADOR_NUMBER is not configured" do
    with_whatsapp_number(nil) do
      get admin_order_path(@order)

      assert_response :success
      assert_select "a", text: "Enviar pedido por WhatsApp", count: 0
      assert_match "no disponible", response.body
    end
  end

  test "show displays a Descargar PNG button wired to the stable #order-receipt id" do
    get admin_order_path(@order)

    assert_response :success
    assert_select "#order-receipt", count: 1
    assert_select "[data-controller=?][data-receipt-export-target-id-value=?][data-receipt-export-filename-value=?]",
      "receipt-export", "order-receipt", @order.receipt_filename
    assert_select "button[data-action=?]", "receipt-export#download", text: "Descargar PNG"
    assert_select "[data-receipt-export-target=?]", "status"
  end

  test "production (read-only) also sees the Descargar PNG button" do
    sign_out @admin
    production_user = User.create!(email: "orders-production-png@example.com", password: "password123", role: "production")
    sign_in production_user

    get admin_order_path(@order)

    assert_response :success
    assert_select "button", text: "Descargar PNG"
  ensure
    production_user&.destroy
  end

  test "the receipt block shows order number, customer, order date, delivery date, quantity, unit price, subtotal and total" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 2)
    order.save! # total_cents = 600 (price_cents 300 * 2)

    get admin_order_path(order)

    assert_response :success
    assert_match order.number, response.body
    assert_match @customer.name, response.body
    assert_match order.created_at.strftime("%d/%m/%Y"), response.body
    assert_match order.delivery_date.strftime("%d/%m/%Y"), response.body
    assert_select ".hans-receipt-col-unit", text: /\$3/
    assert_select ".hans-receipt-total-amount", text: "$6"
  end

  test "the administrative section is visually separate from the receipt block and stays out of it" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    order.order_items.build(product: @product, quantity: 1)
    order.save!
    order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")

    get admin_order_path(order)

    assert_response :success
    assert_match "Información administrativa", response.body

    receipt_node = css_select(".hans-receipt").first
    assert_not_nil receipt_node, "expected a .hans-receipt block in the response"
    receipt_html = receipt_node.to_html

    assert_no_match "Registrar pago", receipt_html
    assert_no_match "Pagos registrados", receipt_html
    assert_no_match "Eliminar", receipt_html
    assert_no_match "Editar pedido", receipt_html
  end

  test "no raw 'Cash on delivery' English text leaks in the admin view either" do
    order = Order.new(customer: @customer, delivery_date: Date.tomorrow, payment_method_selected: "cash_on_delivery")
    order.order_items.build(product: @product, quantity: 1)
    order.save!

    get admin_order_path(order)

    assert_response :success
    assert_no_match(/cash on delivery/i, response.body)
  end

  test "the admin new-order payment method select never offers two identical-looking options" do
    get new_admin_order_path

    assert_response :success
    options = css_select("select#order_payment_method_selected option").map(&:text)
    assert_equal options.uniq, options
  end
  test "an admin can reassign an existing order without changing its payments or payment state" do
    new_customer = Customer.create!(name: "Nuevo Cliente", active: true)
    payment = @order.payments.create!(amount_cents: 300, paid_at: Time.current, payment_method: "cash_on_delivery")
    original_total = @order.reload.total_cents

    patch admin_order_path(@order), params: {
      order: { customer_id: new_customer.id, delivery_date: @order.delivery_date, status: @order.status }
    }

    assert_redirected_to admin_order_path(@order)
    @order.reload
    assert_equal new_customer, @order.customer
    assert_equal original_total, @order.total_cents
    assert_equal 300, @order.amount_paid_cents
    assert_equal "partial", @order.payment_status
    assert_equal @order.id, payment.reload.order_id
    assert_equal 0, @customer.orders.not_canceled.sum(:total_cents)
    assert_equal 0, @customer.orders.not_canceled.sum(:amount_paid_cents)
    assert_equal original_total, new_customer.orders.not_canceled.sum(:total_cents)
    assert_equal 300, new_customer.orders.not_canceled.sum(:amount_paid_cents)
  end

  test "edit shows active customers, selects the current customer, and warns when payments exist" do
    other_customer = Customer.create!(name: "Otro Cliente", active: true)
    inactive_customer = Customer.create!(name: "Cliente Inactivo", active: false)
    @order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")

    get edit_admin_order_path(@order)

    assert_response :success
    assert_select "select#order_customer_id option[value=?][selected]", @customer.id.to_s
    assert_select "select#order_customer_id option[value=?]", other_customer.id.to_s
    assert_select "select#order_customer_id option[value=?]", inactive_customer.id.to_s, count: 0
    assert_select ".alert-warning", text: /pagos registrados.*saldo pendiente.*nuevo cliente/
  end

  test "an invalid update re-renders the edit form with the customer selector" do
    patch admin_order_path(@order), params: {
      order: { customer_id: "", delivery_date: @order.delivery_date, status: @order.status }
    }

    assert_response :unprocessable_entity
    assert_select "select#order_customer_id option[value=?]", @customer.id.to_s
  end


  private

  def next_sunday
    next_weekday(0)
  end

  def next_weekday(wday)
    date = Date.tomorrow
    date += 1 until date.wday == wday
    date
  end

  def with_whatsapp_number(value)
    original = ENV["WHATSAPP_OBRADOR_NUMBER"]
    ENV["WHATSAPP_OBRADOR_NUMBER"] = value
    yield
  ensure
  end
end
