# app/models/customer.rb
class Customer < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, allow_blank: true

  scope :active, -> { where(active: true) }
end