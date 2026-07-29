# app/models/user.rb
class User < ApplicationRecord
  belongs_to :customer, optional: true

  devise :database_authenticatable, :recoverable, :rememberable, :validatable

  enum :role, {
    customer: "customer",
    admin: "admin",
    production: "production"
  }, default: "customer"

  validates :role, presence: true

  def admin?
    role == "admin"
  end

  def production?
    role == "production"
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