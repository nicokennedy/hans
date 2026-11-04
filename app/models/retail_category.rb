# Categoría del catálogo minorista (tienda online). Administrable desde HANS: nada fijo en
# código. Independiente de las categorías mayoristas (Category). Una categoría con productos no
# se borra: se desactiva.
class RetailCategory < ApplicationRecord
  has_many :retail_products, dependent: :restrict_with_error

  before_validation { self.name = name.to_s.squish }

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { case_sensitive: false, message: "ya existe" }
  validates :position, numericality: { only_integer: true }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, Arel.sql("lower(retail_categories.name)"), :id) }

  def deletable?
    !retail_products.exists?
  end
end
