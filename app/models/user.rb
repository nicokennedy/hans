# app/models/user.rb
class User < ApplicationRecord
  belongs_to :customer, optional: true

  devise :database_authenticatable, :recoverable, :rememberable, :validatable

  enum :role, {
    customer: "customer",
    admin: "admin"
  }, default: "customer"

  validates :role, presence: true

  def admin?
    role == "admin"
  end
end