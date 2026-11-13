require "test_helper"
require_relative "../../support/retail_helpers"
require_relative "../../support/retail_catalog_helpers"

# Compras simultáneas contra el stock online, con transacciones reales en hilos distintos (los tests
# transaccionales no sirven acá): cada prueba borra lo que crea.
class Retail::OnlineStockConcurrencyTest < ActiveSupport::TestCase
  include RetailHelpers
  include RetailCatalogHelpers

  self.use_transactional_tests = false

  setup do
    setup_retail
    RetailFulfillmentSetting.current
    @now = Time.zone.local(2026, 11, 9, 10)
    @shop = catalog_category("Concurrencia #{rand(1_000_000)}", active: true)
    @product = catalog_product("Box limitado #{rand(1_000_000)}", category: @shop, active: true, price: "10.000")
    RetailCatalog::PhotoUpload.add(product: @product, files: [image_upload("pixel.png")])
    @variant = @product.variants.first
  end

  teardown do
    orders = RetailOrder.where(id: RetailOrderItem.where(retail_product_variant_id: @variant.id).select(:retail_order_id))
    ids = orders.pluck(:id)
    RetailOrderItem.where(retail_order_id: ids).delete_all
    RetailOrderStatusChange.where(retail_order_id: ids).delete_all
    RetailOrderConfirmationChange.where(retail_order_id: ids).delete_all
    StockMovement.where(retail_order_id: ids).delete_all
    RetailOrder.where(id: ids).delete_all
    # Sin transacción que lo deshaga: el archivo de la foto se borra ya (no queda para un job), así no
    # le sobra un blob a otros tests del mismo proceso.
    blobs = @product.photos.map { |photo| photo.image.blob }
    @product.photos.each(&:destroy)
    blobs.compact.each(&:purge)
    @product.reload.destroy
    @shop.destroy
    [@mini, @torta].each(&:destroy)
    @category.destroy
    @customer.destroy
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

  def place(quantity, token)
    Retail::PlaceStoreOrder.call(
      attributes: { buyer_name: "Cliente #{token}", buyer_phone: "223 5550000", buyer_email: "c@example.com", delivery_kind: "pickup",
                    delivery_date: (Date.new(2026, 11, 11)).iso8601, planned_payment_method: "transfer", notes: "" },
      cart: { @variant.id.to_s => quantity }, request_token: token, now: @now
    )
  end

  test "dos compras simultáneas de la última unidad: solo una pasa y el stock nunca queda negativo" do
    @variant.update!(stock_quantity: 1)
    results = in_threads(2) { |i| place(1, "store-race-#{i}-#{SecureRandom.hex(3)}") }

    assert_equal 1, results.count(&:ok?), results.map(&:errors).inspect
    assert_equal 0, @variant.reload.stock_quantity
    assert_equal 1, RetailOrderItem.where(retail_product_variant_id: @variant.id).count
  end

  test "seis compras simultáneas con 10 unidades: se venden como máximo 10" do
    @variant.update!(stock_quantity: 10)
    results = in_threads(6) { |i| place(3, "store-many-#{i}-#{SecureRandom.hex(3)}") }

    assert_equal 3, results.count(&:ok?), results.map(&:errors).inspect
    assert_equal 1, @variant.reload.stock_quantity
    assert_equal 9, RetailOrderItem.where(retail_product_variant_id: @variant.id).sum(:quantity)
  end

  test "el mismo envío repetido a la vez (doble toque): un pedido y una sola reserva" do
    @variant.update!(stock_quantity: 5)
    token = "store-double-#{SecureRandom.hex(4)}"
    results = in_threads(3) { place(2, token) }

    assert results.all?(&:ok?), results.map(&:errors).inspect
    assert_equal 1, results.map { |r| r.record.id }.uniq.size
    assert_equal 3, @variant.reload.stock_quantity
  end

  test "cancelación y compra simultáneas: el stock termina exacto" do
    @variant.update!(stock_quantity: 2)
    first = place(2, "store-first-#{SecureRandom.hex(3)}").record
    assert_equal 0, @variant.reload.stock_quantity

    results = in_threads(2) do |i|
      i.zero? ? Retail::ChangeStatus.call(order: first, to_status: "canceled", user: @admin) : place(1, "store-late-#{SecureRandom.hex(3)}")
    end

    sold = RetailOrder.where(id: RetailOrderItem.where(retail_product_variant_id: @variant.id).select(:retail_order_id)).where.not(status: "canceled")
                      .joins(:retail_order_items).sum("retail_order_items.quantity")
    assert results.first.ok?
    assert_equal 2 - sold, @variant.reload.stock_quantity, "stock = 2 − lo vendido vigente"
  end
end
