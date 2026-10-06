require "test_helper"

# Edición de la configuración (mínimo y lote) desde /admin/stock. Solo admin;
# nunca toca físico, fecha de control, estado activo ni genera movimientos.
class Admin::StockConfigEditTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "cfgedit-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "cfgedit-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    customer = Customer.create!(name: "CfgEditCustomer#{rand(1_000_000)}", active: true)
    @customer_user = User.create!(email: "cfgedit-customer-#{rand(1_000_000)}@example.com", password: "password123", role: "customer", customer: customer)
    @pool_prep = Preparation.create!(name: "Base Cheesecake CfgEdit #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    @started = Date.new(2026, 10, 5)
    @item = StockItem.create!(stockable: @pool_prep, active: true, quantity: 32, minimum_quantity: 73, stock_tracking_started_on: @started)
  end

  def patch_config(attrs)
    patch update_config_admin_stock_item_path(@item), params: { stock_item: attrs }
  end

  test "el panel muestra el link Editar a un admin y no a production" do
    sign_in @admin
    get admin_stock_path
    assert_select "a[href=?]", edit_config_admin_stock_item_path(@item), text: "Editar"

    sign_out @admin
    sign_in @production
    get admin_stock_path
    assert_response :success
    assert_select "a[href=?]", edit_config_admin_stock_item_path(@item), count: 0
  end

  test "admin ve el formulario con mínimo y lote, y no con físico ni fecha ni activo" do
    sign_in @admin
    get edit_config_admin_stock_item_path(@item)
    assert_response :success
    assert_select "input[name='stock_item[minimum_quantity]'][value='73.0']"
    assert_select "input[name='stock_item[production_batch_size]']"
    assert_select "input[name='stock_item[quantity]']", count: 0
    assert_select "input[name='stock_item[stock_tracking_started_on]']", count: 0
    assert_select "input[name='stock_item[active]']", count: 0
  end

  test "admin cambia el mínimo 73 -> 40: persiste y vuelve a /admin/stock" do
    sign_in @admin
    patch_config(minimum_quantity: "40")

    assert_redirected_to admin_stock_path
    assert_equal BigDecimal("40"), @item.reload.minimum_quantity
  end

  test "admin cambia el lote y también puede dejarlo vacío (NULL)" do
    sign_in @admin
    patch_config(minimum_quantity: "73", production_batch_size: "22")
    assert_equal BigDecimal("22"), @item.reload.production_batch_size

    patch_config(minimum_quantity: "73", production_batch_size: "")
    assert_redirected_to admin_stock_path
    assert_nil @item.reload.production_batch_size
  end

  test "editar la configuración no cambia físico, fecha de control, activo ni genera movimientos" do
    sign_in @admin
    assert_no_difference "StockMovement.count" do
      patch_config(minimum_quantity: "40", production_batch_size: "10")
    end

    @item.reload
    assert_equal BigDecimal("32"), @item.quantity
    assert_equal @started, @item.stock_tracking_started_on
    assert @item.active?
  end

  test "los campos no permitidos se ignoran aunque vengan en el request" do
    other = Preparation.create!(name: "Otra CfgEdit #{rand(1_000_000)}", yield_quantity: 1, yield_unit: "un", stock_only: true)
    sign_in @admin
    assert_no_difference "StockMovement.count" do
      patch_config(minimum_quantity: "40", quantity: "999", active: "0", stock_tracking_started_on: "2020-01-01", stockable_id: other.id, stockable_type: "Preparation")
    end

    @item.reload
    assert_equal BigDecimal("40"), @item.minimum_quantity
    assert_equal BigDecimal("32"), @item.quantity
    assert @item.active?
    assert_equal @started, @item.stock_tracking_started_on
    assert_equal @pool_prep, @item.stockable
  end

  test "valores inválidos se rechazan y no cambian nada" do
    sign_in @admin
    [
      { minimum_quantity: "-1" },
      { minimum_quantity: "" },
      { minimum_quantity: "abc" },
      { minimum_quantity: "40", production_batch_size: "0" },
      { minimum_quantity: "40", production_batch_size: "-5" }
    ].each do |attrs|
      patch_config(attrs)
      assert_response :unprocessable_entity, "debería rechazar #{attrs.inspect}"
    end

    @item.reload
    assert_equal BigDecimal("73"), @item.minimum_quantity
    assert_nil @item.production_batch_size
    assert_equal 0, StockMovement.count
  end

  test "production no puede ver ni guardar la configuración" do
    sign_in @production
    get edit_config_admin_stock_item_path(@item)
    assert_redirected_to admin_production_index_path

    patch_config(minimum_quantity: "40")
    assert_redirected_to admin_production_index_path
    assert_equal BigDecimal("73"), @item.reload.minimum_quantity
  end

  test "un cliente tampoco puede editar la configuración" do
    sign_in @customer_user
    patch_config(minimum_quantity: "40")
    assert_redirected_to dashboard_path
    assert_equal BigDecimal("73"), @item.reload.minimum_quantity
  end

  test "sin sesión redirige al login" do
    patch_config(minimum_quantity: "40")
    assert_redirected_to new_user_session_path
    assert_equal BigDecimal("73"), @item.reload.minimum_quantity
  end

  test "el panel refleja de inmediato el nuevo mínimo y el lote" do
    sign_in @admin
    patch_config(minimum_quantity: "40", production_batch_size: "22")
    follow_redirect!

    assert_response :success
    assert_match "Mínimo: 40 un", response.body
    assert_match "Configuración de #{@pool_prep.name} actualizada: mínimo 40 un, lote de 22 un.", response.body
    assert_equal BigDecimal("32"), @item.reload.quantity
  end

  test "la acción update existente (pantalla del producto) sigue funcionando" do
    sign_in @admin
    patch admin_stock_item_path(@item), params: { stock_item: { minimum_quantity: 50 } }
    assert_equal BigDecimal("50"), @item.reload.minimum_quantity
  end
end
