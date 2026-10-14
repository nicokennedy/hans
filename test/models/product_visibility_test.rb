require "test_helper"
require_relative "../support/visibility_helpers"

class ProductVisibilityTest < ActiveSupport::TestCase
  include VisibilityHelpers

  setup { setup_visibility }

  test "un producto nuevo queda disponible para todos por defecto" do
    product = Product.create!(name: "Nuevo #{rand(1_000_000)}", category: @category, price_cents: 100, cost_cents: 10)

    assert product.all_customers?
    assert_equal "all_customers", product.customer_visibility
    assert_equal "all", product.customer_visibility_before_type_cast
    assert product.available_to?(@cafe_a)
    assert product.available_to?(nil)
    assert_empty product.authorized_customers
  end

  test "la columna por defecto es 'all' y no admite nulos: los productos existentes quedan sin restricción" do
    column = Product.columns_hash["customer_visibility"]

    assert_equal "all", column.default
    assert_not column.null
    # un producto insertado como lo hacía el sistema antes de la migración (sin la columna) queda público
    id = Product.connection.insert("INSERT INTO products (name, category_id, price_cents, active, created_at, updated_at) VALUES ('Legacy #{rand(1_000_000)}', #{@category.id}, 100, true, NOW(), NOW())")
    assert Product.find(id).all_customers?
    assert Product.find(id).available_to?(@cafe_b)
  end

  test "restringido a un cliente" do
    assert @exclusive_a.selected_customers?
    assert @exclusive_a.available_to?(@cafe_a)
    assert_not @exclusive_a.available_to?(@cafe_b)
    assert_not @exclusive_a.available_to?(nil)
  end

  test "restringido a varios clientes" do
    assert_equal [@cafe_a, @cafe_b, @cafe_c].map(&:id).sort, @special_abc.authorized_customer_ids.sort
    [@cafe_a, @cafe_b, @cafe_c].each { |customer| assert @special_abc.available_to?(customer) }
    assert_not @special_abc.available_to?(Customer.create!(name: "Otro #{rand(1_000_000)}", active: true))
  end

  test "restringido sin clientes es inválido" do
    product = Product.new(name: "Sin clientes #{rand(1_000_000)}", category: @category, price_cents: 100, customer_visibility: "selected_customers")

    assert_not product.valid?
    assert_includes product.errors.full_messages.join, "al menos un cliente"

    @exclusive_a.authorized_customers = []
    assert_not @exclusive_a.valid?
  end

  test "valor de visibilidad inválido no rompe: queda inválido" do
    product = Product.new(name: "X #{rand(1_000_000)}", category: @category, price_cents: 100, customer_visibility: "otro")
    assert_not product.valid?
  end

  test "editar los clientes habilitados" do
    @exclusive_a.update!(authorized_customer_ids: [@cafe_b.id, @cafe_c.id])

    assert_equal [@cafe_b.id, @cafe_c.id].sort, @exclusive_a.reload.authorized_customer_ids.sort
    assert_not @exclusive_a.available_to?(@cafe_a)
    assert @exclusive_a.available_to?(@cafe_b)
  end

  test "pasar de restringido a todos libera el producto y limpia los clientes" do
    @exclusive_a.update!(customer_visibility: "all_customers")

    assert @exclusive_a.reload.all_customers?
    assert_equal 0, ProductCustomerAccess.where(product_id: @exclusive_a.id).count
    assert @exclusive_a.available_to?(@cafe_b)
  end

  test "no admite asociaciones duplicadas" do
    assert_raises(ActiveRecord::RecordInvalid) { ProductCustomerAccess.create!(product: @exclusive_a, customer: @cafe_a) }
    assert_raises(ActiveRecord::RecordNotUnique) do
      ProductCustomerAccess.new(product: @exclusive_a, customer: @cafe_a).save!(validate: false)
    end
    @exclusive_a.authorized_customer_ids = [@cafe_a.id, @cafe_a.id]
    assert_equal 1, ProductCustomerAccess.where(product_id: @exclusive_a.id, customer_id: @cafe_a.id).count
  end

  test "scope available_to: públicos + restringidos al cliente, combinable con activo" do
    inactive_public = make_product("Inactivo #{rand(1_000_000)}", 100, active: false)
    inactive_exclusive = make_product("Inactivo excl #{rand(1_000_000)}", 100, active: false, customers: [@cafe_a])

    a = Product.available_to(@cafe_a)
    b = Product.available_to(@cafe_b)

    assert_includes a, @rogel
    assert_includes a, @exclusive_a
    assert_includes a, @special_abc
    assert_includes b, @rogel
    assert_not_includes b, @exclusive_a
    assert_includes b, @special_abc
    assert_not_includes Product.active.available_to(@cafe_a), inactive_public
    assert_not_includes Product.active.available_to(@cafe_a), inactive_exclusive
    assert_equal [@rogel.id], Product.available_to(nil).where(id: [@rogel.id, @exclusive_a.id, @special_abc.id]).pluck(:id)
    assert_equal Product.available_to(@cafe_a).to_a.sort_by(&:id), Product.available_to(@cafe_a.id).to_a.sort_by(&:id)
  end

  test "el scope no duplica productos ni hace consultas por producto" do
    5.times { |i| make_product("Más #{i} #{rand(1_000_000)}", 100, customers: [@cafe_a, @cafe_b]) }

    ids = Product.available_to(@cafe_a).pluck(:id)
    assert_equal ids.uniq, ids

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { Product.active.available_to(@cafe_a).to_a }
    assert_equal 1, queries
  end

  test "configurar la visibilidad no cambia precios, costos ni stock" do
    before = [@rogel.price_cents, @rogel.cost_cents, StockItem.count, StockMovement.count]
    @rogel.update!(customer_visibility: "selected_customers", authorized_customers: [@cafe_a])

    assert_equal before, [@rogel.reload.price_cents, @rogel.cost_cents, StockItem.count, StockMovement.count]
  end

  test "borrar un cliente borra solo su permiso, no el producto" do
    customer = Customer.create!(name: "Temporal #{rand(1_000_000)}", active: true)
    product = make_product("Temp #{rand(1_000_000)}", 100, customers: [customer, @cafe_a])

    customer.destroy!

    assert_equal [@cafe_a.id], product.reload.authorized_customer_ids
  end
end
