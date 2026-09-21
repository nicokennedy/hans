require "test_helper"

class Admin::DeliverySettingsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: "deliverysettings-admin@example.com", password: "password123", role: "admin")
    sign_in @admin
    DeliverySetting.current.update!(exceptional_available_dates: [])
  end

  test "shows the exceptional dates section with the add form" do
    get admin_delivery_settings_path

    assert_response :success
    assert_match "Fechas excepcionales de entrega", response.body
    assert_match "Habilitar fecha", response.body
  end

  test "lists currently enabled exceptional dates with a disable action" do
    tuesday = Date.new(2026, 10, 6)
    DeliverySetting.current.add_exceptional_date!(tuesday)

    get admin_delivery_settings_path

    assert_response :success
    assert_match "06/10/2026", response.body
    assert_match "Deshabilitar", response.body
  end

  test "shows an empty state when there are no exceptional dates" do
    get admin_delivery_settings_path

    assert_response :success
    assert_match "No hay fechas excepcionales habilitadas", response.body
  end
end
