require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"
require_relative "../../support/box_helpers"
require_relative "../../support/xlsx_reader"

# Pedidos minoristas del administrador con cajas personalizables (Etapa 2): cargar una caja en un
# pedido manual, editar la composición de un pedido de la tienda (los cambios se acuerdan por
# WhatsApp), historial de cambios, planilla de producción con totales por sabor y Excel.
class Admin::RetailOrderBoxesTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include RetailHelpers
  include RetailCatalogHelpers
  include BoxHelpers

  setup do
    setup_retail
    @mix = create_mix_box(publish: false)
    @x12, @x24 = box_variant(@mix, 12), box_variant(@mix, 24)
    @almendra, @maicena, @cacao = @mix.ordered_flavors
    sign_in @admin
  end

  def box_row(variant, quantities, quantity: 1, price: "20.000", id: nil)
    { "kind" => "box", "retail_product_variant_id" => variant.id.to_s, "quantity" => quantity.to_s, "unit_price" => price,
      "composition" => quantities.to_h { |f, q| [f.id.to_s, q.to_s] } }.merge(id ? { "id" => id.to_s } : {})
  end

  def order_params(items)
    base_attributes.merge(items: items.each_with_index.to_h { |row, i| [i.to_s, row] })
  end

  test "pedido manual: el formulario ofrece cajas con sabores y valida la suma exacta" do
    get new_admin_retail_order_path
    assert_select "#retail-add-box"
    assert_select "template[data-retail-order-target=boxTemplate] select option[data-units='24']"

    post admin_retail_orders_path, params: order_params([box_row(@x24, { @almendra => 20 })])
    assert_response :unprocessable_entity
    assert_match "Ítem 1: La caja “#{@mix.name} · Caja x 24” lleva exactamente 24 unidades: elegiste 20 (faltan 4).", response.body
    assert_select ".retail-box-row input[name='items[0][composition][#{@almendra.id}]'][value='20']", 1, "lo cargado no se pierde"

    assert_difference "RetailOrder.count", 1 do
      post admin_retail_orders_path, params: order_params([box_row(@x24, { @almendra => 24 }, quantity: 2), product_row(@mini, 3, "500")])
    end
    order = RetailOrder.order(:id).last
    box = order.retail_order_items.find(&:box?)
    assert_equal ["#{@mix.name} · Caja x 24", 2, 2_000_000, "Almendra × 24"], [box.display_name, box.quantity, box.unit_price_cents, box.composition_text]
    assert_equal [@mix.id, @x24.id], [box.retail_product_id, box.retail_product_variant_id]
    assert_equal 2 * 2_000_000 + 3 * 50_000, order.subtotal_cents
  end

  test "editar la composición de un pedido: se valida, queda en el historial y el resto no cambia" do
    order = create_retail(items: [box_row(@x24, { @almendra => 12, @maicena => 12 }), manual_row("Torta especial", 1, "15000")])
    box = order.retail_order_items.find(&:box?)

    get edit_admin_retail_order_path(order)
    assert_select ".retail-box-row select option[value='#{@x24.id}'][selected]"
    assert_select ".retail-box-row input[name='items[0][composition][#{@almendra.id}]'][value='12']"
    assert_select ".retail-box-row input[name='items[0][composition][#{@maicena.id}]'][value='12']"

    torta = order.retail_order_items.reject(&:box?).first
    rows = [box_row(@x24, { @almendra => 6, @maicena => 6, @cacao => 12 }, id: box.id), manual_row("Torta especial", 1, "15000").merge("id" => torta.id.to_s)]
    patch admin_retail_order_path(order), params: order_params(rows)
    assert_redirected_to admin_retail_order_path(order)

    box.reload
    assert_equal "Almendra × 6, Maicena × 6, Cacao × 12", box.composition_text
    change = order.retail_order_status_changes.order(:id).last
    assert_equal @admin, change.user
    assert_equal "Composición de #{@mix.name} · Caja x 24: antes Almendra × 12, Maicena × 12; ahora Almendra × 6, Maicena × 6, Cacao × 12", change.note

    get admin_retail_order_path(order)
    assert_select "#retail-items .retail-item-composition", /Almendra × 6, Maicena × 6, Cacao × 12/
    assert_match "antes Almendra × 12, Maicena × 12", response.body

    # Guardar sin cambios no agrega historial.
    assert_no_difference "RetailOrderStatusChange.count" do
      patch admin_retail_order_path(order), params: order_params(rows)
    end
  end

  test "cambiar de presentación no borra la composición: si no coincide, pide completarla" do
    order = create_retail(items: [box_row(@x24, { @almendra => 24 })])
    box = order.retail_order_items.first

    patch admin_retail_order_path(order), params: order_params([box_row(@x12, { @almendra => 24 }, id: box.id, price: "11.000")])
    assert_response :unprocessable_entity
    assert_match "lleva exactamente 12 unidades: elegiste 24 (sobran 12)", response.body
    assert_equal "Almendra × 24", box.reload.composition_text
    assert_equal @x24.id, box.retail_product_variant_id

    patch admin_retail_order_path(order), params: order_params([box_row(@x12, { @almendra => 6, @cacao => 6 }, id: box.id, price: "11.000")])
    assert_redirected_to admin_retail_order_path(order)
    box.reload
    assert_equal [@x12.id, "#{@mix.name} · Caja x 12", "Almendra × 6, Cacao × 6", 1_100_000], [box.retail_product_variant_id, box.display_name, box.composition_text, box.unit_price_cents]
    assert_match "ahora #{@mix.name} · Caja x 12: Almendra × 6, Cacao × 6", order.retail_order_status_changes.order(:id).last.note
  end

  test "un sabor deshabilitado después se puede conservar, pero no agregar; y una caja quitada queda registrada" do
    order = create_retail(items: [box_row(@x24, { @almendra => 12, @cacao => 12 }), manual_row("Extra", 1, "100")])
    box = order.retail_order_items.find(&:box?)
    extra = order.retail_order_items.reject(&:box?).first
    @cacao.update!(active: false)

    get edit_admin_retail_order_path(order)
    assert_select ".retail-box-row label", text: "Cacao (no disponible)"

    keep = [box_row(@x24, { @almendra => 10, @cacao => 14 }, id: box.id), manual_row("Extra", 1, "100").merge("id" => extra.id.to_s)]
    patch admin_retail_order_path(order), params: order_params(keep)
    assert_redirected_to admin_retail_order_path(order)
    assert_equal "Almendra × 10, Cacao × 14", box.reload.composition_text

    other = create_retail(items: [box_row(@x24, { @almendra => 24 })])
    patch admin_retail_order_path(other), params: order_params([box_row(@x24, { @almendra => 12, @cacao => 12 }, id: other.retail_order_items.first.id)])
    assert_response :unprocessable_entity
    assert_match "“Cacao” ya no está disponible", response.body

    patch admin_retail_order_path(order), params: order_params([manual_row("Extra", 1, "100").merge("id" => extra.id.to_s)])
    assert_redirected_to admin_retail_order_path(order)
    assert_match "Caja quitada: #{@mix.name} · Caja x 24 (Almendra × 10, Cacao × 14)", order.retail_order_status_changes.order(:id).last.note
  end

  test "planilla de producción: detalle de cada caja y total por sabor de los pedidos confirmados; Excel con los sabores" do
    date = Date.new(2026, 10, 18)
    create_retail(items: [box_row(@x24, { @almendra => 12, @maicena => 12 }, quantity: 2)])
    create_retail(items: [box_row(@x12, { @almendra => 12 })])
    awaiting = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, user: nil, source: "store", request_token: "store-x",
                                      items: [box_row(@x12, { @cacao => 12 })]).record
    assert awaiting.confirmation_awaiting?

    sheet = ProductionDaySheet.for(date)
    totals = sheet.flavor_totals.map { |row| [row.flavor_name, row.units] }
    assert_equal [["Almendra", 36], ["Maicena", 24]], totals, "2 cajas × 12 + 12; los pendientes no suman"
    assert_includes sheet.special_items.map(&:composition_text), "Cada caja: Almendra × 12, Maicena × 12"

    get admin_production_path(date)
    assert_select "#production-flavor-totals tr", text: /Almendra\s*36/
    assert_select ".production-special .production-composition", text: "Cada caja: Almendra × 12, Maicena × 12"
    get print_admin_production_path(date)
    assert_select "#print-flavor-totals tr", text: /Maicena\s*24/

    xlsx = XlsxReader.new(Retail::ExcelExporter.new(RetailOrder.all).call)
    rows = xlsx.rows("Detalle de productos")
    assert_equal "Sabores (por caja)", rows.first.last
    assert_includes rows.map(&:last), "Almendra × 12, Maicena × 12"
  end

  test "los pedidos sin cajas no cambian: el formulario y el guardado siguen igual" do
    order = create_retail(items: [product_row(@mini, 2, "500"), manual_row("Torta", 1, "9000")])
    get edit_admin_retail_order_path(order)
    assert_select "[data-retail-order-target=list] .retail-box-row", 0
    patch admin_retail_order_path(order), params: order_params(item_rows_for(order))
    assert_redirected_to admin_retail_order_path(order)
    assert order.retail_order_items.reload.none?(&:box?)
    assert_equal 1, order.retail_order_status_changes.count, "solo 'Pedido creado'"
  end
end
