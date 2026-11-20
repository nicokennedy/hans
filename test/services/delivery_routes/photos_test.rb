require "test_helper"
require_relative "../../support/delivery_route_helpers"

# R4 (D9): foto del remito firmado y excepción "no quiso firmar".
class DeliveryRoutes::PhotosTest < ActiveSupport::TestCase
  include DeliveryRouteHelpers

  setup do
    setup_delivery_data
    @order = create_order(create_customer("Café Aurora"))
    @route = DeliveryRoutes::Create.call(date: @date, order_ids: [@order.id], user: @admin, driver: @driver).route
    @stop = @route.active_stops.first
    DeliveryRoutes::Deliveries.new(@stop, @driver).deliver
  end

  def photos(user = @driver)
    DeliveryRoutes::Photos.new(@route, user)
  end

  test "a photo resolves the pending receipt, linked to stop, route and order, once per form" do
    assert @stop.reload.receipt_photo_pending?
    token = SecureRandom.uuid
    result = photos.attach(@stop, receipt_photo, request_token: token)
    assert result.ok?, result.errors.inspect
    assert photos.attach(@stop, receipt_photo, request_token: token).already
    assert_equal 1, DeliveryPhoto.count
    photo = result.photo
    assert_equal [@route, @stop, @driver, @order], [photo.delivery_route, photo.delivery_stop, photo.taken_by, photo.delivery_stop.order]
    assert photo.image.attached?
    assert_not @stop.reload.receipt_photo_pending?
  end

  test "non images are refused and the receipt stays pending" do
    result = photos.attach(@stop, receipt_photo("document.pdf"), request_token: SecureRandom.uuid)
    assert_not result.ok?
    assert_match "Quedó pendiente", result.errors.join
    assert @stop.reload.receipt_photo_pending?
  end

  test "if photo storage is not available the upload is refused and the stop stays pending" do
    RetailCatalog::PhotoStorage.stub(:enabled?, false) do
      result = photos.attach(@stop, receipt_photo, request_token: SecureRandom.uuid)
      assert_not result.ok?
      assert_match "Quedó pendiente", result.errors.join
    end
    assert @stop.reload.receipt_photo_pending?
    assert_equal "delivered", @stop.delivery_status, "la entrega no se pierde"
  end

  test "customer refused to sign is a recorded exception" do
    assert photos.no_signature(@stop).ok?
    @stop.reload
    assert_equal ["no_signature", @driver], [@stop.receipt_exception, @stop.receipt_exception_by]
    assert_not @stop.receipt_photo_pending?
  end

  test "a fully paid delivery needs no photo" do
    collect(@route, @stop, @order.balance_due_cents)
    assert_not @stop.reload.receipt_photo_required?
  end

  test "another driver cannot add photos" do
    assert_not photos(create_driver("Emilio")).attach(@stop, receipt_photo, request_token: SecureRandom.uuid).ok?
  end
end
