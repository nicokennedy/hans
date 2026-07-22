require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "a visitor sees the sign-in CTA and none of the removed catalog blocks" do
    get root_path

    assert_response :success
    assert_select "a.btn-hans", text: "Ingresar a la tienda"
    assert_select "a.btn-hans[href=?]", new_user_session_path
    assert_no_match "Catálogo mayorista", response.body
    assert_no_match "Productos destacados", response.body
  end

  test "an authenticated customer sees the portal CTA, not the sign-in one" do
    customer = Customer.create!(name: "Cliente Home", active: true)
    user = User.create!(email: "home-customer@example.com", password: "password123", role: "customer", customer: customer)
    sign_in user

    get root_path

    assert_response :success
    assert_select "a.btn-hans", text: "Ir a mi portal"
    assert_select "a.btn-hans[href=?]", dashboard_path
    assert_no_match "Ingresar a la tienda", response.body
  end

  test "an authenticated admin sees the panel CTA, not the sign-in one" do
    admin = User.create!(email: "home-admin@example.com", password: "password123", role: "admin")
    sign_in admin

    get root_path

    assert_response :success
    assert_select "a.btn-hans", text: "Ir al panel"
    assert_select "a.btn-hans[href=?]", admin_root_path
    assert_no_match "Ingresar a la tienda", response.body
  end
end
