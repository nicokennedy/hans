# Zona de envío a domicilio de la tienda minorista. El cliente la elige a mano (la cobertura es
# orientativa, no un límite geográfico automático) y el costo sale de acá, nunca del cliente.
# Cada pedido guarda la zona, su nombre y el costo aplicado (shipping_cents): si el precio cambia
# después, los pedidos anteriores conservan el suyo. Una zona usada por pedidos no se borra: se
# desactiva.
class RetailDeliveryZone < ApplicationRecord
  MAX_PRICE_CENTS = 100_000_000 # $1.000.000

  has_many :retail_orders, foreign_key: :delivery_zone_id, inverse_of: :delivery_zone, dependent: :restrict_with_error

  before_validation do
    self.name = name.to_s.squish
    self.coverage = coverage.to_s.squish.presence
  end

  validates :name, presence: true, length: { maximum: 60 }
  validates :name, uniqueness: { case_sensitive: false, message: "ya existe" }
  validates :coverage, length: { maximum: 300 }, allow_nil: true
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_PRICE_CENTS }, allow_nil: true
  validates :position, numericality: { only_integer: true }
  validate :price_input_is_valid

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, Arel.sql("lower(retail_delivery_zones.name)"), :id) }

  # Precio como se escribe en pesos ("5.000"); inválido -> error de validación.
  def price=(text)
    @price_input = text.to_s.strip
    self.price_cents = @price_input.empty? ? nil : Retail::Money.parse_pesos(@price_input)
  end

  def price
    @price_input || (price_cents && Retail::Money.format_pesos(price_cents))
  end

  def deletable?
    !retail_orders.exists?
  end

  private

  def price_input_is_valid
    errors.add(:price, "no es un importe válido") if @price_input.present? && price_cents.nil?
    errors.add(:price, "es obligatorio") if @price_input == "" || (@price_input.nil? && price_cents.nil?)
  end
end
