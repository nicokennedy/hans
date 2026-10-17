require "test_helper"

# Reproduce el 404 de producción: https://<host>/8ad45326-... es lo que queda de la URL temporal
# blob: de un remito generado en el navegador cuando se abre en otro dispositivo o se recarga.
class ExpiredFileLinksControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PRODUCTION_LINK = "/8ad45326-06e7-4f85-8b90-68e47caeb697".freeze

  test "the receipt link from the production logs explains it expired instead of a 404" do
    get PRODUCTION_LINK

    assert_response :gone
    assert_select "#expired-file-link h1", text: "Este enlace de remito ya no está disponible"
    assert_select "a[href=?]", new_user_session_path, text: "Ingresar a HANS"
  end

  test "admins and production users get a way back to the receipts screen" do
    %w[admin production].each do |role|
      sign_in User.create!(email: "expired-#{role}@example.com", password: "password123", role: role)
      get PRODUCTION_LINK

      assert_response :gone
      assert_select "a[href=?]", receipts_admin_orders_path, text: "Imprimir remitos por fecha"
      sign_out :user
    end
  end

  test "uppercase UUIDs are handled too" do
    get PRODUCTION_LINK.upcase

    assert_response :gone
  end

  test "other unknown root paths are still a plain 404" do
    ["/no-existe", "/8ad45326-06e7-4f85-8b90", "/8ad45326-06e7-4f85-8b90-68e47caeb697/extra"].each do |path|
      get path
      assert_response :not_found, path
    end
  end
end
