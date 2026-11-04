# Producto del catálogo minorista (tienda online), independiente del catálogo mayorista:
# nombre, descripción, fotos y precio minorista propios. Puede vincularse opcionalmente con un
# producto mayorista (product) para usarlo en producción cuando exista el checkout; el vínculo
# no cambia precios, stock ni el producto mayorista, y no crea pedidos ni movimientos.
# Sin vínculo, se venderá como producto especial. El stock no condiciona la disponibilidad.
class RetailProduct < ApplicationRecord
  MAX_PRICE_CENTS = 2_000_000_000
  CODE_FORMAT = /\A[A-Z0-9][A-Z0-9-]*\z/

  belongs_to :retail_category
  belongs_to :product, optional: true # producto mayorista vinculado (solo lectura)
  has_many :photos, -> { order(primary: :desc, position: :asc, id: :asc) }, class_name: "RetailProductPhoto", dependent: :destroy, inverse_of: :retail_product
  has_one :primary_photo, -> { where(primary: true) }, class_name: "RetailProductPhoto", inverse_of: :retail_product
  # Ítems de pedidos de la tienda que salieron de este producto. Si el producto se borra, los ítems
  # conservan nombre, cantidad y precio (la base limpia el vínculo: on_delete nullify).
  has_many :retail_order_items, dependent: :nullify

  before_validation :normalize_fields
  before_validation :assign_code, on: :create

  validates :name, presence: true, length: { maximum: 150 }
  validates :description, length: { maximum: 2000 }, allow_blank: true
  validates :code, presence: true, length: { maximum: 40 }, format: { with: CODE_FORMAT, message: "solo puede tener letras, números y guiones" }
  validates :code, uniqueness: { case_sensitive: false, message: "ya lo usa otro producto" }
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_PRICE_CENTS }, allow_nil: true
  validates :position, numericality: { only_integer: true }
  validate :price_input_is_valid

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, Arel.sql("lower(retail_products.name)"), :id) }
  # Lo que muestra y vende la tienda pública: el mismo criterio que #ready_for_store? (activo,
  # categoría activa y foto principal), resuelto en la base.
  scope :for_store, -> {
    active.joins(:retail_category).merge(RetailCategory.active)
      .where(id: RetailProductPhoto.where(primary: true).select(:retail_product_id))
  }

  # Precio como se escribe en pesos ("4.500", "4500,50"); inválido -> error de validación.
  def price=(text)
    @price_input = text.to_s.strip
    self.price_cents = @price_input.empty? ? nil : Retail::Money.parse_pesos(@price_input)
  end

  def price
    @price_input || (price_cents && Retail::Money.format_pesos(price_cents))
  end

  # Qué le falta para mostrarse en la tienda pública: producto activo, categoría activa y
  # fotografía principal (ver .for_store).
  def publication_issues
    issues = []
    issues << "Inactivo" unless active?
    issues << "Categoría inactiva" if retail_category && !retail_category.active?
    issues << "Sin fotografía principal" unless primary_photo
    issues
  end

  def ready_for_store?
    publication_issues.empty?
  end

  # Se puede borrar si está inactivo, para no borrar por error algo visible. Las fotos se borran con
  # él; los pedidos que lo incluían conservan sus ítems (nombre, cantidad y precio).
  def deletable?
    !active?
  end

  # Copia para cargar más rápido un producto parecido: mismos datos, código nuevo, inactiva y sin
  # fotos (las fotos se suben de nuevo para que cada producto tenga las suyas).
  def duplicate
    self.class.new(
      name: "#{name} (copia)".first(150), description: description, price_cents: price_cents,
      retail_category: retail_category, product: product, featured: false, active: false,
      position: position
    )
  end

  private

  def normalize_fields
    self.name = name.to_s.squish.presence
    self.description = description.to_s.strip.presence
    self.code = code.to_s.strip.upcase.gsub(/\s+/, "-").presence
  end

  # Código interno único derivado del nombre si no se escribió uno (ej. "BOX-DE-COOKIES-2").
  def assign_code
    return if code.present? || name.blank?

    base = "#{I18n.transliterate(name).upcase.gsub(/[^A-Z0-9]+/, '-').gsub(/\A-|-\z/, '')}".first(34).presence || "PRODUCTO"
    candidate = base
    suffix = 1
    while self.class.where("lower(code) = ?", candidate.downcase).exists?
      suffix += 1
      candidate = "#{base}-#{suffix}"
    end
    self.code = candidate
  end

  def price_input_is_valid
    errors.add(:price, "no es un importe válido") if @price_input.present? && price_cents.nil?
    errors.add(:price, "es obligatorio") if @price_input == "" || (@price_input.nil? && price_cents.nil?)
  end
end
