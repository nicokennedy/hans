# app/models/user.rb
class User < ApplicationRecord
  belongs_to :customer, optional: true
  has_many :push_subscriptions, dependent: :destroy

  devise :database_authenticatable, :recoverable, :rememberable, :validatable

  enum :role, {
    customer: "customer",
    admin: "admin",
    production: "production",
    driver: "driver"
  }, default: "customer"

  # Sesión del celular corporativo del repartidor (Repartos, decisión D7): siempre queda
  # "recordado", con una cookie que vence a los 60 días SIN uso (cada uso la renueva).
  # Cambiar la contraseña la invalida (el token sale del hash de la contraseña) y "Salir"
  # la invalida en todos los dispositivos (expire_all_remember_me_on_sign_out). El resto
  # de los roles no cambia: nunca se los recuerda porque el login no ofrece "recordarme".
  DRIVER_REMEMBER_FOR = 60.days

  validates :role, presence: true

  def admin?
    role == "admin"
  end

  def production?
    role == "production"
  end

  # Repartidor: solo usa el portal /reparto. No tiene cliente asociado ni acceso a /admin.
  def driver?
    role == "driver"
  end

  # --- Devise rememberable, solo para el repartidor ---------------------------------------

  def remember_me
    driver? || super
  end

  def remember_expires_at
    driver? ? DRIVER_REMEMBER_FOR.from_now : super
  end

  def extend_remember_period
    driver? || super
  end

  # Igual que Devise::Models::Rememberable#remember_me?, pero con el plazo del repartidor
  # (Devise solo admite un plazo por modelo).
  def remember_me?(token, generated_at)
    return super unless driver?

    generated_at = time_from_json(generated_at) if generated_at.is_a?(String)

    generated_at.is_a?(Time) &&
      DRIVER_REMEMBER_FOR.ago < generated_at &&
      generated_at > (remember_created_at || Time.now).utc &&
      Devise.secure_compare(rememberable_value, token)
  end

  # Perfil interno de solo lectura para el equipo de producción: puede ver
  # pedidos y el listado de producción, pero nunca crear/editar/eliminar nada.
  def admin_or_production?
    admin? || production?
  end

  def can_view_orders?
    admin_or_production?
  end

  def can_view_production?
    admin_or_production?
  end
end