require "test_helper"

class Users::ManageTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(name: "Laura", email: "laura-#{SecureRandom.hex(2)}@example.com", password: "password123", role: "admin")
    @manager = Users::Manage.new(@admin)
  end

  test "creates internal users with a one-time temporary password and only its hash" do
    result = @manager.create(name: "Chiara", email: "Chiara@Example.com", role: "driver")
    assert result.ok?, result.errors.inspect
    user = result.user
    assert_equal ["Chiara", "chiara@example.com", "driver"], [user.name, user.email, user.role]
    assert user.active?
    assert user.must_change_password?
    assert_match(/\A[A-Za-z2-9]{4}-[A-Za-z2-9]{4}-[A-Za-z2-9]{4}\z/, result.password)
    assert user.valid_password?(result.password)
    assert_not_includes user.attributes.values.map(&:to_s).join, result.password, "la contraseña legible no se guarda"
    assert_equal "created", user.user_events.last.event_type
    assert_equal @admin, user.user_events.last.actor
  end

  test "temporary passwords are different every time" do
    assert_equal 20, Array.new(20) { Users::TemporaryPassword.generate }.uniq.size
  end

  test "only internal roles can be assigned, never customer" do
    assert_not @manager.create(name: "X", email: "x@example.com", role: "customer").ok?
    user = @manager.create(name: "P", email: "p@example.com", role: "production").user
    assert_not @manager.update(user, name: "P", email: "p@example.com", role: "customer").ok?
    assert_equal "production", user.reload.role
  end

  test "customer accounts are not managed here" do
    customer = Customer.create!(name: "Café", active: true)
    customer_user = User.create!(email: "cafe-#{SecureRandom.hex(2)}@example.com", password: "password123", role: "customer", customer: customer)
    assert_not @manager.update(customer_user, name: "X", email: customer_user.email, role: "admin").ok?
    assert_not @manager.set_active(customer_user, false).ok?
    assert_not @manager.reset_password(customer_user).ok?
    assert_equal "customer", customer_user.reload.role
  end

  test "editing records the changes and role changes" do
    user = @manager.create(name: "Emilio", email: "emilio@example.com", role: "production").user
    assert @manager.update(user, name: "Emilio R.", email: "emilio@example.com", role: "driver").ok?
    types = user.user_events.reload.map(&:event_type)
    assert_equal %w[created updated role_changed], types
    assert_equal({ "from" => "production", "to" => "driver" }, user.user_events.last.data)
  end

  test "an admin cannot change their own role or deactivate themselves" do
    other = @manager.create(name: "Otra admin", email: "otra@example.com", role: "admin").user
    assert other.active?
    assert_not @manager.update(@admin, name: "Laura", email: @admin.email, role: "production").ok?
    assert_not @manager.set_active(@admin, false).ok?
    assert @admin.reload.admin?
    assert @admin.active?
  end

  test "HANS never runs out of active admins" do
    other = @manager.create(name: "Otra admin", email: "otra@example.com", role: "admin").user
    other_manager = Users::Manage.new(other)
    User.where(role: "admin").where.not(id: [@admin.id, other.id]).update_all(active: false)

    assert other_manager.set_active(@admin, false).ok?, "con otra admin activa se puede desactivar"
    result = Users::Manage.new(User.create!(email: "aux-#{SecureRandom.hex(2)}@example.com", password: "password123", role: "admin", active: false)).set_active(other, false)
    assert_not result.ok?
    assert_match "último administrador activo", result.errors.join
  end

  test "a driver with pending routes cannot change role until they are reassigned" do
    driver = @manager.create(name: "Chiara", email: "chiara@example.com", role: "driver").user
    route = DeliveryRoute.create!(date: Date.current + 1, driver: driver, created_by: @admin)
    result = @manager.update(driver, name: "Chiara", email: "chiara@example.com", role: "production")
    assert_not result.ok?
    assert_match "recorridos pendientes", result.errors.join

    route.update_column(:date, Date.current - 1)
    assert @manager.update(driver, name: "Chiara", email: "chiara@example.com", role: "production").ok?
  end

  test "deactivating and reactivating keeps history and warns about pending routes" do
    driver = @manager.create(name: "Chiara", email: "chiara@example.com", role: "driver").user
    DeliveryRoute.create!(date: Date.current, driver: driver, created_by: @admin)
    result = @manager.set_active(driver, false)
    assert result.ok?
    assert_match "recorridos pendientes", result.warnings.join
    assert_not driver.reload.active?
    assert_not driver.active_for_authentication?
    assert @manager.set_active(driver, true).ok?
    assert_equal %w[created deactivated activated], driver.user_events.reload.map(&:event_type)
  end

  test "resetting a password gives a new temporary one and forces a change" do
    user = @manager.create(name: "Chiara", email: "chiara@example.com", role: "driver").user
    user.update!(password: "mi-clave-nueva", password_confirmation: "mi-clave-nueva", must_change_password: false)
    result = @manager.reset_password(user)
    assert result.ok?
    assert user.reload.must_change_password?
    assert user.valid_password?(result.password)
    assert_not user.valid_password?("mi-clave-nueva")
    assert_not @manager.reset_password(@admin).ok?, "no se restablece la propia"
  end

  test "the user history cannot be edited" do
    event = @manager.create(name: "Chiara", email: "chiara@example.com", role: "driver").user.user_events.first
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(event_type: "updated") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.destroy }
  end
end
