require "test_helper"

class ProductionRoleAuthorizationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @category = Category.create!(name: "Alfajores ProdRoleTest", position: 1, active: true)
    @product = Product.create!(name: "Alfajor ProdRoleTest", category: @category, internal_category: "Alfajores", price_cents: 500, cost_cents: 200, active: true, position: 1)
    @customer = Customer.create!(name: "Cliente ProdRoleTest", active: true)

    @order = Order.new(customer: @customer, delivery_date: Date.tomorrow)
    @order.order_items.build(product: @product, quantity: 2)
    @order.save!

    @admin = User.create!(email: "prodrole-admin@example.com", password: "password123", role: "admin")
    @production_user = User.create!(email: "prodrole-production@example.com", password: "password123", role: "production")
    @customer_user = User.create!(email: "prodrole-customer@example.com", password: "password123", role: "customer", customer: @customer)

    @raw_material = RawMaterial.create!(
      name: "Manteca ProdRoleTest", category: "Lácteos", purchase_price_cents: 100_000,
      purchase_quantity: 1, purchase_unit: "kg", base_unit: "kg"
    )

    @preparation = Preparation.create!(name: "Masa Sable ProdRoleTest", yield_quantity: 2, yield_unit: "kg")
    @recipe_component = @preparation.recipe_components.create!(component: @raw_material, quantity: 1000, unit: "g")

    @product_recipe = ProductRecipe.create!(product: @product, yield_quantity: 10)
    @product_recipe_component = @product_recipe.recipe_components.create!(component: @raw_material, quantity: 1, unit: "kg")
  end

  # --- Production: allowed access ---

  test "production can log in normally" do
    post user_session_path, params: { user: { email: @production_user.email, password: "password123" } }
    assert_redirected_to admin_production_index_path
    follow_redirect!
    assert_response :success
  end

  test "production can access the orders index" do
    sign_in @production_user
    get admin_orders_path
    assert_response :success
  end

  test "production can open the detail of any order" do
    sign_in @production_user
    get admin_order_path(@order)
    assert_response :success
    assert_match @order.number, response.body
  end

  test "production can access the production overview" do
    sign_in @production_user
    get admin_production_index_path
    assert_response :success
  end

  test "production can access the printable production view and its print action" do
    sign_in @production_user
    get admin_production_path(@order.delivery_date)
    assert_response :success

    get print_admin_production_path(@order.delivery_date)
    assert_response :success
  end

  test "production can open the WhatsApp order link (plain helper-built URL, no controller round trip)" do
    original = ENV["WHATSAPP_OBRADOR_NUMBER"]
    ENV["WHATSAPP_OBRADOR_NUMBER"] = "5492235275412"
    sign_in @production_user

    get admin_order_path(@order)
    assert_response :success
    assert_match "wa.me/5492235275412", response.body
    assert_match "Enviar pedido por WhatsApp", response.body
  ensure
    ENV["WHATSAPP_OBRADOR_NUMBER"] = original
  end

  # --- Production: blocked access (server-side, not just hidden UI) ---

  test "production cannot access the new-order form" do
    sign_in @production_user
    get new_admin_order_path
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access the edit-order form via direct URL" do
    sign_in @production_user
    get edit_admin_order_path(@order)
    assert_redirected_to admin_production_index_path
  end

  test "production cannot update an order via PATCH, and nothing changes in the database" do
    sign_in @production_user
    original_date = @order.delivery_date

    assert_no_changes -> { @order.reload.delivery_date } do
      patch admin_order_path(@order), params: { order: { delivery_date: original_date + 5.days } }
    end

    assert_redirected_to admin_production_index_path
  end

  test "production cannot create an order" do
    sign_in @production_user

    assert_no_difference "Order.count" do
      post admin_orders_path, params: {
        order: { customer_id: @customer.id, delivery_date: Date.tomorrow, status: "received" },
        order_items: [ { product_id: @product.id, quantity: "1" } ]
      }
    end

    assert_redirected_to admin_production_index_path
  end

  test "production cannot register a payment" do
    sign_in @production_user

    assert_no_difference "Payment.count" do
      post admin_order_payments_path(@order), params: {
        payment: { amount: "5", paid_at: Date.current, payment_method: "cash_on_delivery" }
      }
    end

    assert_redirected_to admin_production_index_path
    assert_equal 0, @order.reload.amount_paid_cents
  end

  test "production cannot delete a payment" do
    payment = @order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")
    sign_in @production_user

    assert_no_difference "Payment.count" do
      delete admin_order_payment_path(@order, payment)
    end

    assert_redirected_to admin_production_index_path
  end

  test "production cannot access products (index, new, edit, update, destroy)" do
    sign_in @production_user

    get admin_products_path
    assert_redirected_to admin_production_index_path

    get new_admin_product_path
    assert_redirected_to admin_production_index_path

    get edit_admin_product_path(@product)
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @product.reload.price_cents } do
      patch admin_product_path(@product), params: { product: { price_cents: 999_999 } }
    end

    assert_no_difference "Product.count" do
      delete admin_product_path(@product)
    end
  end

  test "production cannot access raw materials (index, new, edit, update), and never sees costs or history" do
    sign_in @production_user

    get admin_raw_materials_path
    assert_redirected_to admin_production_index_path

    get new_admin_raw_material_path
    assert_redirected_to admin_production_index_path

    get edit_admin_raw_material_path(@raw_material)
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @raw_material.reload.purchase_price_cents } do
      patch admin_raw_material_path(@raw_material), params: { raw_material: { purchase_price_amount: "999999" } }
    end
    assert_redirected_to admin_production_index_path
  end

  test "production sees no link to Materias primas in the navbar, and is redirected away from a direct URL" do
    sign_in @production_user

    get admin_orders_path
    assert_no_match "Materias primas", response.body

    get admin_raw_materials_path
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access preparations (index, new, edit, update), and never sees costs" do
    sign_in @production_user

    get admin_preparations_path
    assert_redirected_to admin_production_index_path

    get new_admin_preparation_path
    assert_redirected_to admin_production_index_path

    get edit_admin_preparation_path(@preparation)
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @preparation.reload.name } do
      patch admin_preparation_path(@preparation), params: { preparation: { name: "Hackeada" } }
    end
    assert_redirected_to admin_production_index_path
  end

  test "production cannot add, edit or remove recipe components via direct mutation" do
    sign_in @production_user

    assert_no_difference "RecipeComponent.count" do
      post admin_preparation_recipe_components_path(@preparation), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "1", unit: "kg" }
      }
    end
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @recipe_component.reload.quantity } do
      patch admin_preparation_recipe_component_path(@preparation, @recipe_component), params: { recipe_component: { quantity: "999" } }
    end
    assert_redirected_to admin_production_index_path

    assert_no_difference "RecipeComponent.count" do
      delete admin_preparation_recipe_component_path(@preparation, @recipe_component)
    end
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access product recipes (new, create, edit, update, activate, deactivate) or their components" do
    sign_in @production_user

    get new_admin_product_product_recipe_path(@product)
    assert_redirected_to admin_production_index_path

    get edit_admin_product_product_recipe_path(@product)
    assert_redirected_to admin_production_index_path

    other_product = Product.create!(name: "Otro Producto ProdRoleTest", category: @category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    assert_no_difference "ProductRecipe.count" do
      post admin_product_product_recipe_path(other_product), params: { product_recipe: { yield_quantity: "5" } }
    end
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @product_recipe.reload.yield_quantity } do
      patch admin_product_product_recipe_path(@product), params: { product_recipe: { yield_quantity: "999" } }
    end
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @product.reload.cost_source } do
      post activate_admin_product_product_recipe_path(@product)
    end
    assert_redirected_to admin_production_index_path

    post deactivate_admin_product_product_recipe_path(@product)
    assert_redirected_to admin_production_index_path

    assert_no_difference "RecipeComponent.count" do
      post admin_product_product_recipe_recipe_components_path(@product), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "1", unit: "kg" }
      }
    end
    assert_redirected_to admin_production_index_path

    assert_no_changes -> { @product_recipe_component.reload.quantity } do
      patch admin_product_product_recipe_recipe_component_path(@product, @product_recipe_component), params: { recipe_component: { quantity: "999" } }
    end
    assert_redirected_to admin_production_index_path

    assert_no_difference "RecipeComponent.count" do
      delete admin_product_product_recipe_recipe_component_path(@product, @product_recipe_component)
    end
    assert_redirected_to admin_production_index_path
  end

  test "production sees no link to Preparaciones in the navbar, and is redirected away from a direct URL" do
    sign_in @production_user

    get admin_orders_path
    assert_no_match "Preparaciones", response.body

    get admin_preparations_path
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access customers or collections" do
    sign_in @production_user
    get admin_customers_path
    assert_redirected_to admin_production_index_path

    get admin_customer_path(@customer)
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access product import routes" do
    sign_in @production_user

    get import_admin_products_path
    assert_redirected_to admin_production_index_path

    assert_no_difference "Product.count" do
      post preview_import_admin_products_path
    end
  end

  test "production cannot access the admin dashboard hub" do
    sign_in @production_user
    get admin_root_path
    assert_redirected_to admin_production_index_path
  end

  test "production cannot access the customer-facing cart, dashboard or own-orders screens" do
    sign_in @production_user

    get dashboard_path
    assert_redirected_to admin_production_index_path

    get cart_path
    assert_redirected_to admin_production_index_path

    get orders_path
    assert_redirected_to admin_production_index_path
  end

  test "production is not signed out for lacking a customer association" do
    sign_in @production_user
    get admin_production_index_path
    assert_response :success # would be a sign-out redirect to sign-in if ensure_active_customer! misfired
  end

  # --- Production: hidden sensitive info / controls (server-rendered, not just CSS) ---

  test "production order detail hides edit link, payment history, and the register-payment form" do
    @order.payments.create!(amount_cents: 100, paid_at: Time.current, payment_method: "cash_on_delivery")
    sign_in @production_user

    get admin_order_path(@order)

    assert_response :success
    assert_no_match "Editar pedido", response.body
    assert_no_match "Información administrativa", response.body
    assert_no_match "Registrar pago", response.body
    assert_select "button", text: "Eliminar", count: 0
  end

  test "production orders index hides the new-order button and financial figures per card" do
    sign_in @production_user

    get admin_orders_path

    assert_response :success
    assert_no_match "Nuevo pedido", response.body
    assert_no_match "Saldo:", response.body
  end

  test "production never sees cost_cents or internal cost figures anywhere in orders/production views" do
    sign_in @production_user

    get admin_order_path(@order)
    assert_no_match(/cost_cents/, response.body)

    get admin_production_path(@order.delivery_date)
    assert_no_match(/cost_cents/, response.body)
  end

  # --- Navigation ---

  test "production sees only Pedidos and Producción in the navbar, no admin-only links" do
    sign_in @production_user
    get admin_orders_path

    assert_match "Pedidos", response.body
    assert_match "Producción", response.body
    assert_no_match "Clientes", response.body
    assert_no_match ">Productos<", response.body
  end

  # --- Admin: retains full access ---

  test "admin retains full access to write actions blocked for production" do
    sign_in @admin

    get new_admin_order_path
    assert_response :success

    get edit_admin_order_path(@order)
    assert_response :success

    get admin_products_path
    assert_response :success

    get admin_customers_path
    assert_response :success

    get admin_raw_materials_path
    assert_response :success
    assert_match "Materias primas", response.body

    get edit_admin_raw_material_path(@raw_material)
    assert_response :success

    get admin_preparations_path
    assert_response :success
    assert_match "Preparaciones", response.body

    get edit_admin_preparation_path(@preparation)
    assert_response :success
    assert_match "Manteca ProdRoleTest", response.body

    get edit_admin_product_product_recipe_path(@product)
    assert_response :success
    assert_match "Manteca ProdRoleTest", response.body
  end

  # --- Customer: unaffected, isolated ---

  test "customer retains normal access to their own dashboard/cart/orders" do
    sign_in @customer_user
    get dashboard_path
    assert_response :success
  end

  test "customer still cannot reach admin or production routes" do
    sign_in @customer_user

    get admin_orders_path
    assert_redirected_to dashboard_path

    get admin_production_index_path
    assert_redirected_to dashboard_path
  end

  test "customer cannot access raw materials via direct URL" do
    sign_in @customer_user

    get admin_raw_materials_path
    assert_redirected_to dashboard_path

    get edit_admin_raw_material_path(@raw_material)
    assert_redirected_to dashboard_path
  end

  test "customer cannot access preparations or recipe components via direct URL" do
    sign_in @customer_user

    get admin_preparations_path
    assert_redirected_to dashboard_path

    get edit_admin_preparation_path(@preparation)
    assert_redirected_to dashboard_path

    assert_no_difference "RecipeComponent.count" do
      post admin_preparation_recipe_components_path(@preparation), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "1", unit: "kg" }
      }
    end
    assert_redirected_to dashboard_path
  end

  test "customer cannot access product recipes or their components via direct URL" do
    sign_in @customer_user

    get edit_admin_product_product_recipe_path(@product)
    assert_redirected_to dashboard_path

    assert_no_changes -> { @product.reload.cost_source } do
      post activate_admin_product_product_recipe_path(@product)
    end
    assert_redirected_to dashboard_path

    assert_no_difference "RecipeComponent.count" do
      post admin_product_product_recipe_recipe_components_path(@product), params: {
        recipe_component: { component_ref: "RawMaterial:#{@raw_material.id}", quantity: "1", unit: "kg" }
      }
    end
    assert_redirected_to dashboard_path
  end

  test "customer cannot view another customer's order" do
    other_customer = Customer.create!(name: "Otro Cliente ProdRoleTest", active: true)
    other_order = Order.new(customer: other_customer, delivery_date: Date.tomorrow)
    other_order.order_items.build(product: @product, quantity: 1)
    other_order.save!

    sign_in @customer_user
    get order_path(other_order)
    assert_response :not_found
  end

  test "customer never sees cost_cents figures" do
    sign_in @customer_user
    get dashboard_path
    assert_no_match(/cost_cents/, response.body)
  end
end
