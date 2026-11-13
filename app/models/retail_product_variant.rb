# Variante vendible de un producto de la tienda minorista: un tamaño de torta ("18 cm", "22 cm") o una
# presentación ("Caja x 6"). Todo producto tiene al menos una; los productos simples tienen una sola,
# sin nombre. Cada variante tiene precio, disponibilidad y stock online propios, y el pedido guarda la
# variante elegida con su nombre y su precio (el precio siempre sale de acá, en el servidor).
#
# description (opcional): lo propio de la variante (ej. "Mínimo 4 por variedad" de un box); el detail
# de la tienda la muestra debajo de la descripción del producto cuando se elige esa variante.
#
# Orden: position de menor a mayor tamaño. El catálogo muestra el precio de la variante más grande
# disponible (RetailProduct#display_variant).
#
# Stock online (independiente del stock de producción/mayorista):
#  - stock_quantity NULL = sin límite (no se representa con un número ficticio);
#  - un número = unidades que todavía se pueden vender por la tienda. Lo descuentan los pedidos de la
#    tienda pendientes o confirmados y lo devuelven los cancelados o rechazados (Retail::OnlineStock).
class RetailProductVariant < ApplicationRecord
  STOCK_MODES = { "unlimited" => "Sin límite de stock", "limited" => "Stock limitado" }.freeze
  MAX_STOCK = 100_000

  belongs_to :retail_product, inverse_of: :variants
  belongs_to :product, optional: true # producto mayorista propio de esta variante (opcional)
  has_many :retail_order_items, dependent: :nullify

  # Lo que vio el administrador al abrir el formulario: si el stock cambió mientras editaba (porque
  # entró un pedido), no se pisa (ver #stock_unchanged_since_form).
  attr_accessor :stock_quantity_seen

  before_validation :normalize_fields
  before_validation :apply_stock_form

  validates :name, length: { maximum: 60 }
  validates :description, length: { maximum: 2000 }, allow_blank: true
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: RetailProduct::MAX_PRICE_CENTS }, allow_nil: true
  validates :position, numericality: { only_integer: true }
  validates :stock_quantity, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_STOCK }, allow_nil: true
  validate :price_input_is_valid
  validate :stock_input_is_valid
  validate :stock_unchanged_since_form, on: :update

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, :id) }
  scope :purchasable, -> { active.where("retail_product_variants.stock_quantity IS NULL OR retail_product_variants.stock_quantity > 0") }

  def price=(text)
    @price_input = text.to_s.strip
    self.price_cents = @price_input.empty? ? nil : Retail::Money.parse_pesos(@price_input)
  end

  def price
    @price_input || (price_cents && Retail::Money.format_pesos(price_cents))
  end

  # Formulario: "unlimited" (por defecto) o "limited" + unidades.
  def stock_mode
    @stock_mode || (stock_quantity.nil? ? "unlimited" : "limited")
  end

  def stock_mode=(value)
    @stock_mode = STOCK_MODES.key?(value.to_s) ? value.to_s : "unlimited"
  end

  # Unidades escritas en el formulario (texto); solo cuentan con stock limitado. Se aplican en
  # before_validation (#apply_stock_form), así no importa el orden en que llegan los campos.
  def stock_input=(text)
    @stock_input = text.to_s.strip
  end

  def stock_input
    @stock_input || stock_quantity&.to_s
  end

  def limited_stock?
    !stock_quantity.nil?
  end

  def sold_out?
    limited_stock? && stock_quantity <= 0
  end

  def purchasable?
    active? && !sold_out?
  end

  # Producto mayorista para producción: el de la variante o, si no tiene, el del producto.
  def wholesale_product
    product || retail_product&.product
  end

  # "Torta nuez · 22 cm" (o solo el nombre del producto si es su única variante sin nombre).
  def full_name
    [retail_product&.name, name.presence].compact.join(" · ")
  end

  def label
    name.presence || "Única"
  end

  private

  def normalize_fields
    self.name = name.to_s.squish.presence
    self.description = description.to_s.strip.presence
  end

  def apply_stock_form
    case @stock_mode
    when "unlimited" then self.stock_quantity = nil
    when "limited"
      self.stock_quantity = @stock_input.to_s.match?(/\A\d{1,9}\z/) ? @stock_input.to_i : nil if @stock_input
    end
  end

  def price_input_is_valid
    errors.add(:price, "no es un importe válido") if @price_input.present? && price_cents.nil?
    errors.add(:price, "es obligatorio") if price_cents.nil? && !(@price_input.present?)
  end

  def stock_input_is_valid
    return unless @stock_mode == "limited" && stock_quantity.nil?

    errors.add(:stock_quantity, "tiene que ser un número entero de 0 o más")
  end

  def stock_unchanged_since_form
    return if stock_quantity_seen.nil? || !will_save_change_to_stock_quantity?

    seen = stock_quantity_seen.to_s.strip.empty? ? nil : stock_quantity_seen.to_i
    return if seen == stock_quantity_in_database

    errors.add(:stock_quantity, "cambió mientras editabas (entraron o se cancelaron pedidos): ahora hay #{stock_quantity_in_database || 'sin límite'}. Revisalo y guardá de nuevo")
  end
end
