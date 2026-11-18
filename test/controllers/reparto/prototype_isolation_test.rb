require "test_helper"

# Repartos en MODO DEMOSTRACIÓN (R1): los prototipos se sirven a usuarios autorizados y no
# pueden tocar datos de HANS. Abrirlos no escribe nada en la base y el HTML no tiene ningún
# mecanismo para mandarle datos al servidor (sin formularios, fetch, XHR ni sockets): lo que
# "guardan" queda en el navegador.
class Reparto::PrototypeIsolationTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PROTOTYPES = %w[prototypes/reparto.html prototypes/repartos-admin.html].freeze
  SERVER_CALLS = /\bfetch\s*\(|XMLHttpRequest|sendBeacon|WebSocket|EventSource|<form\b|\.submit\s*\(|importScripts|navigator\.serviceWorker/

  setup do
    @admin = User.create!(email: "demo-admin@example.com", password: "password123", role: "admin")
    @driver = User.create!(email: "demo-driver@example.com", password: "password123", role: "driver")
    @production = User.create!(email: "demo-production@example.com", password: "password123", role: "production")
  end

  test "the prototypes have no way to send data to the server" do
    PROTOTYPES.each do |path|
      source = Rails.root.join(path).read
      assert_no_match SERVER_CALLS, source, "#{path} no debe comunicarse con el servidor"
      assert_match "MODO DEMOSTRACIÓN", source, "#{path} debe decir que es una demostración"
    end
  end

  test "the prototypes only link to HANS demo exits and Google" do
    PROTOTYPES.each do |path|
      Rails.root.join(path).read.scan(/(?:href|src)="([^"]+)"/).flatten.each do |url|
        next if url.start_with?("https://fonts.googleapis.com", "https://fonts.gstatic.com", "https://www.google.com/maps/")
        next if url.include?("' +") # enlaces armados en JS (salida de la demo, mapas, fotos locales)

        flunk "#{path} enlaza a #{url}"
      end
    end
  end

  test "opening every demo screen writes nothing to the database" do
    tracked = [Order, OrderItem, OrderEvent, Payment, CustomerPayment, Customer, Expense, Obligation,
               OutgoingPayment, StockMovement, AdministrationAttachment, RetailOrder, User]

    counts = -> { tracked.to_h { |model| [model.name, model.count] } }
    before = counts.call

    sign_in @admin
    [admin_delivery_routes_demo_path, admin_delivery_routes_prototype_path, reparto_prototype_path, reparto_root_path].each do |path|
      get path
      assert_response :success, path
    end

    sign_in @driver
    get reparto_prototype_path
    assert_response :success

    assert_equal before, counts.call
  end

  test "admins reach both demos from the Repartos menu without signing in as the driver" do
    sign_in @admin
    get admin_root_path
    assert_select "a[href=?]", admin_delivery_routes_demo_path, text: "Repartos"

    get admin_delivery_routes_demo_path
    assert_response :success
    assert_select "a[href=?]", reparto_prototype_path
    assert_select "a[href=?]", admin_delivery_routes_prototype_path
    assert_match "MODO DEMOSTRACIÓN", response.body

    get reparto_prototype_path
    assert_match "window.HANS_EXIT_URL = #{admin_delivery_routes_demo_path.to_json}", response.body
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the driver demo sends the driver back to the driver portal" do
    sign_in @driver
    get reparto_prototype_path
    assert_match "window.HANS_EXIT_URL = #{reparto_root_path.to_json}", response.body
  end

  test "only admins open the Repartos admin page" do
    sign_in @driver
    get admin_delivery_routes_demo_path
    assert_redirected_to reparto_root_path

    sign_in @production
    get admin_delivery_routes_demo_path
    assert_redirected_to admin_production_index_path
    get reparto_prototype_path
    assert_redirected_to admin_production_index_path
  end

  test "signed-out visitors cannot open any demo" do
    [admin_delivery_routes_demo_path, admin_delivery_routes_prototype_path, reparto_prototype_path].each do |path|
      get path
      assert_redirected_to new_user_session_path, path
    end
  end
end
