require "test_helper"

class Admin::UsersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(name: "Laura", email: "laura-users@example.com", password: "password123", role: "admin")
    @production = User.create!(name: "Prod", email: "prod-users@example.com", password: "password123", role: "production")
    @customer = Customer.create!(name: "Café Usuarios", active: true)
    @customer_user = User.create!(email: "cafe-users@example.com", password: "password123", role: "customer", customer: @customer)
  end

  def create_via_ui(name: "Chiara", email: "chiara-ui@example.com", role: "driver")
    post admin_users_path, params: { user: { name: name, email: email, role: role } }
    password = response.body[/<code id="temporary-password"[^>]*>([^<]+)</, 1]
    [User.find_by!(email: email), password]
  end

  test "lists internal users only, with filters" do
    sign_in @admin
    get admin_users_path
    assert_response :success
    assert_match "laura-users@example.com", response.body
    assert_match "prod-users@example.com", response.body
    assert_no_match "cafe-users@example.com", response.body

    get admin_users_path(role: "production", status: "active")
    emails = css_select("tbody td:nth-child(2)").map { |td| td.text.strip }
    assert_includes emails, "prod-users@example.com"
    assert_not_includes emails, "laura-users@example.com"
  end

  test "creating shows the temporary password once and never again" do
    sign_in @admin
    user, password = create_via_ui
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert password.present?
    assert user.valid_password?(password)

    get admin_user_path(user)
    assert_no_match password, response.body
    get admin_users_path
    assert_no_match password, response.body
    assert_no_match user.encrypted_password, response.body
  end

  test "the new user must change the temporary password on first login" do
    sign_in @admin
    user, password = create_via_ui
    sign_out @admin

    post user_session_path, params: { user: { email: user.email, password: password } }
    follow_redirect!
    assert_redirected_to edit_password_change_path
    get reparto_root_path
    assert_redirected_to edit_password_change_path

    patch password_change_path, params: { password: password, password_confirmation: password }
    assert_response :unprocessable_entity
    patch password_change_path, params: { password: "corta", password_confirmation: "corta" }
    assert_response :unprocessable_entity

    patch password_change_path, params: { password: "mi-clave-segura", password_confirmation: "mi-clave-segura" }
    assert_redirected_to reparto_root_path
    assert_not user.reload.must_change_password?
    assert user.valid_password?("mi-clave-segura")
    assert_equal "password_changed", user.user_events.last.event_type
    get reparto_root_path
    assert_response :success, "la sesión sigue abierta después del cambio"
  end

  test "deactivating revokes the open session and blocks login" do
    driver = User.create!(name: "Emilio", email: "emilio-users@example.com", password: "password123", role: "driver")
    sign_in driver
    get reparto_root_path
    assert_response :success

    Users::Manage.new(@admin).set_active(driver, false)
    get reparto_root_path
    assert_redirected_to new_user_session_path

    post user_session_path, params: { user: { email: driver.email, password: "password123" } }
    assert_redirected_to new_user_session_path
    follow_redirect!
    assert_match "Tu acceso está desactivado", response.body
  end

  test "resetting the password closes other sessions" do
    driver = User.create!(name: "Emilio", email: "emilio-reset@example.com", password: "password123", role: "driver")
    sign_in driver
    get reparto_root_path
    assert_response :success

    Users::Manage.new(@admin).reset_password(driver)
    get reparto_root_path
    assert_redirected_to new_user_session_path
  end

  test "records the last successful sign-in without IP" do
    assert_nil @production.last_sign_in_at
    post user_session_path, params: { user: { email: @production.email, password: "wrong-password" } }
    assert_nil @production.reload.last_sign_in_at
    post user_session_path, params: { user: { email: @production.email, password: "password123" } }
    assert_in_delta Time.current, @production.reload.last_sign_in_at, 5
    assert_not User.column_names.any? { |c| c.include?("ip") }
  end

  test "edit, deactivate, activate and reset from the screens, with history" do
    sign_in @admin
    user, = create_via_ui
    patch admin_user_path(user), params: { user: { name: "Chiara B.", email: user.email, role: "production" } }
    assert_redirected_to admin_user_path(user)
    patch deactivate_admin_user_path(user)
    patch activate_admin_user_path(user)
    post reset_password_admin_user_path(user)
    assert_response :success
    assert_match "temporary-password", response.body

    get admin_user_path(user)
    %w[Creó Editó Cambió Desactivó Activó Restableció].each { |word| assert_match word, response.body }
  end

  test "an admin cannot demote or deactivate themselves from the screens" do
    sign_in @admin
    patch admin_user_path(@admin), params: { user: { name: "Laura", email: @admin.email, role: "driver" } }
    assert @admin.reload.admin?
    patch deactivate_admin_user_path(@admin)
    assert @admin.reload.active?
  end

  test "customer accounts cannot be opened from Usuarios" do
    sign_in @admin
    get admin_user_path(@customer_user)
    assert_response :not_found
  end

  test "only admins can manage users" do
    target = @production
    driver = User.create!(name: "Emilio", email: "emilio-perm@example.com", password: "password123", role: "driver")
    { @production => admin_production_index_path, driver => reparto_root_path, @customer_user => dashboard_path }.each do |user, fallback|
      sign_in user
      [-> { get admin_users_path }, -> { get new_admin_user_path }, -> { get admin_user_path(target) },
       -> { post admin_users_path, params: { user: { name: "X", email: "x-#{user.id}@example.com", role: "admin" } } },
       -> { patch admin_user_path(target), params: { user: { name: "X", email: target.email, role: "admin" } } },
       -> { patch deactivate_admin_user_path(target) }, -> { post reset_password_admin_user_path(target) }].each do |request|
        request.call
        assert_redirected_to fallback
      end
    end
    assert_equal "production", target.reload.role
    assert target.active?
    assert_not User.where(role: "admin").where("email LIKE 'x-%'").exists?
  end

  test "existing production and customer access are unchanged" do
    sign_in @production
    get admin_orders_path
    assert_response :success
    sign_in @customer_user
    get dashboard_path
    assert_response :success
  end

  test "the forms that reveal a temporary password do not use Turbo" do
    sign_in @admin
    get new_admin_user_path
    assert_select "form[action=?][data-turbo=false]", admin_users_path
    get admin_user_path(@production)
    assert_select "form[action=?][data-turbo=false]", reset_password_admin_user_path(@production)
  end
end
