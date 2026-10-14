# app/models/customer.rb
class Customer < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error
  has_many :customer_payments, dependent: :restrict_with_error
  # Productos restringidos a este cliente (ver Product#customer_visibility). Solo son permisos de pedido.
  has_many :product_customer_accesses, dependent: :destroy
  has_many :exclusive_products, through: :product_customer_accesses, source: :product

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, allow_blank: true

  scope :active, -> { where(active: true) }
end