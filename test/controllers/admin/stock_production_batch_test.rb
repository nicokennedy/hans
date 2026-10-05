require "test_helper"

class Admin::StockProductionBatchTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "batchui-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "batchui-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    category = Category.create!(name: "BatchUICat#{rand(1_000_000)}", position: 1, active: true)
    @product = Product.create!(name: "Producto BatchUI", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @tapas = Preparation.create!(name: "Tapas Alfajor Sable Orgánico BatchUI", yield_quantity: 1, yield_unit: "un", stock_only: true)
  end

  def pool(physical:, minimum:, batch: nil)
    StockItem.create!(stockable: @tapas, active: true, quantity: physical, minimum_quantity: minimum, production_batch_size: batch)
  end

  test "con lote: muestra PREPARAR n TANDA -> unidades, el faltante, el lote y el stock estimado después" do
    pool(physical: 5, minimum: 10, batch: 22)
    sign_in @admin

    get admin_stock_path

    assert_select ".text-danger", text: /PREPARAR 1 TANDA → 22 un/
    assert_match "Faltan 5 un para el mínimo", response.body
    assert_match "Lote: 22 un", response.body
    assert_match "Stock disponible estimado después: 27 un", response.body
    assert_no_match(/PRODUCIR: 5/, response.body)
  end

  test "con lote y faltante de dos tandas: PREPARAR 2 TANDAS -> 44 un" do
    pool(physical: 0, minimum: 30, batch: 22)
    sign_in @admin

    get admin_stock_path

    assert_select ".text-danger", text: /PREPARAR 2 TANDAS → 44 un/
    assert_match "Faltan 30 un para el mínimo", response.body
  end

  test "sin lote: sigue mostrando PRODUCIR n como siempre" do
    pool(physical: 5, minimum: 10)
    sign_in @admin

    get admin_stock_path

    assert_select ".text-danger", text: /PRODUCIR: 5 un/
    assert_no_match(/PREPARAR/, response.body)
  end

  test "sin faltante no se sugiere ninguna tanda" do
    pool(physical: 30, minimum: 10, batch: 22)
    sign_in @admin

    get admin_stock_path

    assert_no_match(/PREPARAR/, response.body)
    assert_no_match(/PRODUCIR:/, response.body)
  end

  test "la cantidad de '+ Producción' viene pre-completada con lo sugerido, pero es editable y acepta otra cantidad" do
    item = pool(physical: 5, minimum: 10, batch: 22)
    sign_in @production

    get admin_stock_path
    assert_select "form[action=?] input[name=quantity][value=?]", register_production_admin_stock_item_path(item), "22"

    post register_production_admin_stock_item_path(item), params: { quantity: 20 } # hicieron 20, no 22
    assert_redirected_to admin_stock_path
    assert_equal BigDecimal(25), item.reload.quantity
  end

  test "sin lote la cantidad de '+ Producción' arranca vacía" do
    item = pool(physical: 5, minimum: 10)
    sign_in @admin

    get admin_stock_path

    assert_select "form[action=?] input[name=quantity]:not([value])", register_production_admin_stock_item_path(item)
  end

  test "admin configura el lote desde la edición del objeto de stock, y puede borrarlo" do
    item = pool(physical: 5, minimum: 10)
    sign_in @admin

    get edit_admin_preparation_path(@tapas)
    assert_match "Lote de producción", response.body
    assert_match "cantidad que rinde una tanda completa", response.body

    patch admin_stock_item_path(item), params: { stock_item: { minimum_quantity: 10, production_batch_size: "22" } }
    assert_redirected_to edit_admin_preparation_path(@tapas)
    assert_equal BigDecimal(22), item.reload.production_batch_size
    assert_equal BigDecimal(10), item.minimum_quantity # independiente del mínimo

    patch admin_stock_item_path(item), params: { stock_item: { production_batch_size: "" } }
    assert_nil item.reload.production_batch_size
  end

  test "un lote inválido (0 o negativo) se rechaza" do
    item = pool(physical: 5, minimum: 10, batch: 22)
    sign_in @admin

    patch admin_stock_item_path(item), params: { stock_item: { production_batch_size: "0" } }

    assert_equal BigDecimal(22), item.reload.production_batch_size
  end

  test "al habilitar el control de stock se puede informar el lote desde el inicio" do
    sign_in @admin

    post admin_stock_items_path, params: { stock_item: { stockable_type: "Preparation", stockable_id: @tapas.id, active: "1", minimum_quantity: 10, production_batch_size: "22" } }

    assert_equal BigDecimal(22), @tapas.reload.stock_item.production_batch_size
  end

  test "production no puede cambiar el lote" do
    item = pool(physical: 5, minimum: 10)
    sign_in @production

    patch admin_stock_item_path(item), params: { stock_item: { production_batch_size: "22" } }

    assert_nil item.reload.production_batch_size
  end

  test "la ficha de historial también muestra la recomendación de tandas" do
    item = pool(physical: 5, minimum: 10, batch: 22)
    sign_in @admin

    get admin_stock_item_path(item)

    assert_match "PREPARAR 1 TANDA → 22 un", response.body
  end
end
