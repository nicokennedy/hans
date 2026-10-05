require "test_helper"

# El filtrado se hace en el navegador (stock_search_controller.js, lógica en
# stock_search.js y sus tests con node). Acá se cubre lo que pone el servidor:
# el buscador, los nombres para filtrar en cada fila, y que el listado y sus
# acciones sigan intactos.
class Admin::StockSearchTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "stocksearch-admin-#{rand(1_000_000)}@example.com", password: "password123", role: "admin")
    @production = User.create!(email: "stocksearch-production-#{rand(1_000_000)}@example.com", password: "password123", role: "production")
    category = Category.create!(name: "SearchCat#{rand(1_000_000)}", position: 1, active: true)

    @brownie = Product.create!(name: "Cuadrado Brownie SearchTest", category: category, price_cents: 500, cost_cents: 200, active: true, position: 1)
    @budin = Product.create!(name: "Budín de limón SearchTest", category: category, price_cents: 500, cost_cents: 200, active: true, position: 2)
    @cheese = Preparation.create!(name: "Base Cheesecake SearchTest", yield_quantity: 1, yield_unit: "un", stock_only: true)

    @items = [ @brownie, @budin, @cheese ].map do |stockable|
      StockItem.create!(stockable: stockable, active: true, quantity: 3, minimum_quantity: 10, stock_tracking_started_on: Date.new(2026, 1, 1))
    end
  end

  test "el buscador aparece arriba del listado, con su placeholder y la opción de limpiar" do
    sign_in @admin
    get admin_stock_path

    assert_response :success
    assert_select "[data-controller=stock-search]" do
      assert_select "input#stock-search-input[type=search][placeholder=?]", "Buscar producto o base..."
      assert_select "button[data-action=?]", "stock-search#clear", text: /Limpiar/
      assert_select "[data-stock-search-target=empty]", text: "No se encontraron productos."
    end
    assert_select "input#stock-search-input[data-action*=?]", "input->stock-search#filter"
  end

  test "el buscador está antes de la primera fila" do
    sign_in @admin
    get admin_stock_path

    assert_operator response.body.index("stock-search-input"), :<, response.body.index("data-stock-search-target=\"row\"")
  end

  test "cada fila trae el nombre visible del StockItem para filtrar" do
    sign_in @admin
    get admin_stock_path

    names = css_select("[data-stock-search-target=row]").map { |row| row["data-stock-search-name"] }
    assert_equal 3, names.size
    assert_equal [ "Base Cheesecake SearchTest", "Budín de limón SearchTest", "Cuadrado Brownie SearchTest" ], names.sort
    assert_equal @items.map(&:name).map(&:strip).sort, names.sort
  end

  test "el nombre para filtrar coincide con el nombre que se ve en la fila" do
    sign_in @admin
    get admin_stock_path

    css_select("[data-stock-search-target=row]").each do |row|
      visible = row.css("a.fw-bold").first.text.strip
      assert_equal visible, row["data-stock-search-name"]
    end
  end

  test "el listado y sus acciones siguen intactos: historial, producción y conteo de cada fila" do
    sign_in @admin
    get admin_stock_path

    @items.each do |item|
      assert_select "a[href=?]", admin_stock_item_path(item)
      assert_select "form[action=?]", register_production_admin_stock_item_path(item)
      assert_select "form[action=?]", register_count_admin_stock_item_path(item)
    end
    assert_select "[data-controller=stock-search] form", count: @items.size * 2
  end

  test "el campo de búsqueda no está dentro de ningún formulario (no envía nada ni hace requests)" do
    sign_in @admin
    get admin_stock_path

    assert_select "form #stock-search-input", count: 0
    assert_select "[data-stock-search-target=input]", count: 1
  end

  test "production también ve el buscador" do
    sign_in @production
    get admin_stock_path

    assert_response :success
    assert_select "input#stock-search-input"
  end

  test "sin ítems de stock no se muestra el buscador, solo el mensaje de siempre" do
    StockItem.destroy_all
    sign_in @admin
    get admin_stock_path

    assert_response :success
    assert_select "input#stock-search-input", count: 0
    assert_match "Todavía no hay ningún producto ni preparación controlando stock", response.body
  end

  test "abrir la pantalla con el buscador no cambia los datos (solo la conciliación de siempre al cargar)" do
    sign_in @admin

    assert_no_difference [ "StockMovement.count", "StockItem.count" ] do
      get admin_stock_path
    end
    assert_equal [ 3, 3, 3 ], @items.map { |i| i.reload.quantity.to_i }
  end
end
