require "test_helper"
require_relative "../../support/retail_helpers"

class Retail::SaveOrderTest < ActiveSupport::TestCase
  include RetailHelpers

  setup { setup_retail }

  test "crea un pedido con producto de catálogo, precio manual y total exacto" do
    order = create_retail(items: [product_row(@mini, 12, "500")])

    assert_equal "María Pérez", order.buyer_name
    assert_equal @sunday, order.delivery_date
    assert_equal pesos(6_000), order.subtotal_cents
    assert_equal pesos(6_000), order.total_cents
    assert_equal "pending", order.status
    assert_equal "pending", order.payment_status
    item = order.retail_order_items.first
    assert_equal @mini, item.product
    assert_equal @mini.name, item.product_name_snapshot
    assert_equal pesos(500), item.unit_price_cents
    assert_equal pesos(6_000), item.line_total_cents
  end

  test "no usa ni modifica el precio mayorista del producto" do
    order = create_retail(items: [product_row(@mini, 2, "1.234,50")])

    assert_equal 123_450, order.retail_order_items.first.unit_price_cents
    assert_equal 500, @mini.reload.price_cents
  end

  test "el precio es obligatorio (no se autocompleta) pero puede ser cero" do
    result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, items: [product_row(@mini, 1, "")], user: @admin)
    assert_not result.ok?
    assert_match(/precio unitario es obligatorio/, result.errors.join)

    order = create_retail(items: [product_row(@mini, 1, "0")])
    assert_equal 0, order.total_cents
    assert_equal "paid", order.payment_status # total 0: nada que cobrar
  end

  test "producto manual y combinado: subtotal de catálogo + manual + envío editable" do
    order = create_retail(
      attributes: { shipping: "1.500" },
      items: [product_row(@mini, 10, "500"), manual_row("Torta personalizada", 1, "8.000")]
    )

    assert_equal pesos(13_000), order.subtotal_cents
    assert_equal pesos(1_500), order.shipping_cents
    assert_equal pesos(14_500), order.total_cents
    manual = order.retail_order_items.manual.first
    assert_nil manual.product_id
    assert_equal "Torta personalizada", manual.description
    assert_equal 1, order.retail_order_items.catalog.count
    assert_no_difference -> { Product.count } do
      create_retail(items: [manual_row("Otra cosa", 2, "100")])
    end
  end

  test "envío en 0 o vacío es válido" do
    assert_equal pesos(100), create_retail(attributes: { shipping: "0" }, items: [product_row(@mini, 1, "100")]).total_cents
    assert_equal pesos(100), create_retail(attributes: { shipping: "" }, items: [product_row(@mini, 1, "100")]).total_cents
  end

  test "acepta cualquier día de entrega, incluidos domingos y feriados, sin tocar la regla mayorista" do
    [Date.new(2026, 10, 18), Date.new(2026, 10, 12), Date.new(2026, 12, 25), Date.new(2026, 10, 14)].each do |date|
      order = create_retail(attributes: { delivery_date: date.iso8601 })
      assert_equal date, order.delivery_date
    end
    assert_nil DeliveryDateValidator.reason(Date.new(2026, 10, 14)) # miércoles: válido mayorista
    assert DeliveryDateValidator.reason(@sunday).present?, "la regla mayorista no cambió"
  end

  test "validaciones: comprador, fecha, cantidades y producto" do
    call = ->(attrs, items) { Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes(attrs), items: items, user: @admin) }

    assert_match(/nombre y apellido/, call.({ buyer_name: "  " }, [product_row(@mini, 1, "1")]).errors.join)
    assert_match(/fecha de entrega es obligatoria/, call.({ delivery_date: "" }, [product_row(@mini, 1, "1")]).errors.join)
    assert_match(/fecha de entrega no es válida/, call.({ delivery_date: "2026-13-45" }, [product_row(@mini, 1, "1")]).errors.join)
    assert_match(/al menos un producto/, call.({}, []).errors.join)
    assert_match(/cantidad/, call.({}, [product_row(@mini, 0, "1")]).errors.join)
    assert_match(/cantidad/, call.({}, [product_row(@mini, -3, "1")]).errors.join)
    assert_match(/cantidad/, call.({}, [product_row(@mini, "1,5", "1")]).errors.join)
    assert_match(/precio/, call.({}, [product_row(@mini, 1, "abc")]).errors.join)
    assert_match(/precio/, call.({}, [product_row(@mini, 1, "-5")]).errors.join)
    assert_match(/elegí un producto/, call.({}, [{ "kind" => "product", "product_id" => "999999", "quantity" => "1", "unit_price" => "1" }]).errors.join)
    assert_match(/descripción/, call.({}, [manual_row("", 1, "1")]).errors.join)
    assert_match(/tipo de entrega/, call.({ delivery_kind: "drone" }, [product_row(@mini, 1, "1")]).errors.join)
    assert_match(/medio de pago previsto/, call.({ planned_payment_method: "bitcoin" }, [product_row(@mini, 1, "1")]).errors.join)
    assert_match(/envío/, call.({ shipping: "xx" }, [product_row(@mini, 1, "1")]).errors.join)
    assert_equal 0, RetailOrder.count
  end

  test "producto inactivo no se puede agregar a un pedido nuevo" do
    @mini.update!(active: false)
    result = Retail::SaveOrder.call(order: RetailOrder.new, attributes: base_attributes, items: [product_row(@mini, 1, "1")], user: @admin)

    assert_not result.ok?
    assert_match(/inactivo/, result.errors.join)
  end

  test "no crea cliente mayorista ni pedido mayorista" do
    assert_no_difference ["Customer.count", "Order.count", "Payment.count", "CustomerPayment.count"] do
      order = create_retail
      pay_retail(order, "1000")
    end
  end

  test "editar: cantidad, precio, ítems agregados y quitados; se recalcula el total" do
    order = create_retail(items: [product_row(@mini, 12, "500"), manual_row("Especial", 1, "1.000")])
    rows = item_rows_for(order)
    rows[0]["quantity"] = "15"
    rows[1] = nil
    rows = rows.compact + [product_row(@torta, 1, "4.500")]

    order = update_retail(order, attributes: { shipping: "200" }, items: rows)

    assert_equal 2, order.retail_order_items.count
    assert_equal pesos(15 * 500 + 4_500), order.subtotal_cents
    assert_equal pesos(15 * 500 + 4_500 + 200), order.total_cents
    assert_equal 0, order.retail_order_items.manual.count
  end

  test "editar conserva el snapshot del nombre mientras el producto sea el mismo" do
    order = create_retail(items: [product_row(@mini, 1, "500")])
    original = order.retail_order_items.first.product_name_snapshot
    @mini.update!(name: "Nombre nuevo")

    order = update_retail(order, items: item_rows_for(order))
    assert_equal original, order.retail_order_items.first.product_name_snapshot
  end

  test "editar con pagos: los conserva, recalcula saldo y muestra excedente si el total baja" do
    order = create_retail(items: [product_row(@mini, 10, "1.000")]) # 10.000
    assert pay_retail(order, "6.000").ok?

    order = update_retail(order, items: [product_row(@mini, 10, "800").merge("id" => order.retail_order_items.first.id.to_s)]) # 8.000
    assert_equal pesos(6_000), order.amount_paid_cents
    assert_equal pesos(2_000), order.balance_cents
    assert_equal "partial", order.payment_status

    order = update_retail(order, items: [product_row(@mini, 5, "800").merge("id" => order.retail_order_items.first.id.to_s)]) # 4.000 < 6.000 pagado
    assert_equal pesos(4_000), order.total_cents
    assert_equal pesos(6_000), order.amount_paid_cents
    assert_equal pesos(2_000), order.excess_cents
    assert_equal 0, order.pending_balance_cents
    assert_equal "paid", order.payment_status
    assert_equal 1, order.retail_order_payments.count
  end

  test "un pedido editado a otra fecha cambia su fecha de entrega" do
    order = create_retail
    order = update_retail(order, attributes: { delivery_date: "2026-10-25" }, items: item_rows_for(order))
    assert_equal Date.new(2026, 10, 25), order.delivery_date
  end
end
