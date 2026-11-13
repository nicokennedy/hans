# Producto del catálogo minorista (tienda online), independiente del catálogo mayorista:
# nombre, descripción, fotos y precio minorista propios. Puede vincularse opcionalmente con un
# producto mayorista (product) para usarlo en producción cuando exista el checkout; el vínculo
# no cambia precios, stock ni el producto mayorista, y no crea pedidos ni movimientos.
# Sin vínculo, se venderá como producto especial.
#
# Variantes (RetailProductVariant): todo producto tiene al menos una. Los productos simples tienen una
# sola, sin nombre, que se maneja con #price= como antes. Las tortas tienen una por tamaño, cada una
# con precio, disponibilidad y stock online propios. price_cents queda como precio de catálogo: el de
# la variante activa más grande (se sincroniza al guardar); la tienda usa #display_variant, que además
# saltea las agotadas.
#
# Disponibilidad: active publica u oculta el producto entero (con todas sus variantes); cada variante
# se puede deshabilitar o agotar por separado.
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
  # Orden con la tabla explícita: con includes + joins (catálogo) la carga se hace con JOIN y un
  # order(:position) a secas se aplicaba a retail_products, desordenando las variantes.
  has_many :variants, -> { order("retail_product_variants.position", "retail_product_variants.id") }, class_name: "RetailProductVariant", dependent: :destroy, inverse_of: :retail_product, validate: false
  accepts_nested_attributes_for :variants, allow_destroy: true

  before_validation :normalize_fields
  before_validation :assign_code, on: :create
  before_validation :ensure_variant
  before_save :sync_catalog_price

  validates :name, presence: true, length: { maximum: 150 }
  validates :description, length: { maximum: 2000 }, allow_blank: true
  validates :code, presence: true, length: { maximum: 40 }, format: { with: CODE_FORMAT, message: "solo puede tener letras, números y guiones" }
  validates :code, uniqueness: { case_sensitive: false, message: "ya lo usa otro producto" }
  validates :price_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: MAX_PRICE_CENTS }, allow_nil: true
  validates :position, numericality: { only_integer: true }
  validate :variants_are_consistent

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, Arel.sql("lower(retail_products.name)"), :id) }
  # Lo que muestra y vende la tienda pública: el mismo criterio que #ready_for_store? (activo,
  # categoría activa y foto principal), resuelto en la base.
  # Lo que muestra la tienda pública: producto activo, categoría activa, foto principal y al menos una
  # variante habilitada (puede estar agotada: se ve "Agotado" pero no se puede comprar).
  scope :for_store, -> {
    active.joins(:retail_category).merge(RetailCategory.active)
      .where(id: RetailProductPhoto.where(primary: true).select(:retail_product_id))
      .where(id: RetailProductVariant.active.select(:retail_product_id))
  }

  # Precio de un producto de UNA variante, como se escribe en pesos ("4.500", "4500,50"). Con varias
  # variantes el precio se carga en cada una.
  def price=(text)
    single_variant.price = text
  end

  def price
    variants.size <= 1 ? single_variant.price : (price_cents && Retail::Money.format_pesos(price_cents))
  end

  # La única variante de un producto simple (se crea si todavía no tiene).
  def single_variant
    variants.reject(&:marked_for_destruction?).first || variants.build(position: 1)
  end

  # Variantes de menor a mayor tamaño, sin depender de cómo se cargó la asociación.
  def ordered_variants
    variants.reject(&:marked_for_destruction?).sort_by { |v| [v.position.to_i, v.id || Float::INFINITY] }
  end

  def multiple_variants?
    variants.reject(&:marked_for_destruction?).size > 1
  end

  # Variante cuyo precio muestra el catálogo: la más grande que se puede comprar; si están todas
  # agotadas, la más grande habilitada (con "Agotado").
  def display_variant
    active = ordered_variants.select(&:active?)
    active.select(&:purchasable?).last || active.last
  end

  def purchasable?
    variants.any?(&:purchasable?)
  end

  def sold_out?
    variants.any?(&:active?) && !purchasable?
  end

  # Qué le falta para mostrarse en la tienda pública: producto activo, categoría activa y
  # fotografía principal (ver .for_store).
  def publication_issues
    issues = []
    issues << "Inactivo" unless active?
    issues << "Categoría inactiva" if retail_category && !retail_category.active?
    issues << "Sin fotografía principal" unless primary_photo
    issues << "Sin variantes habilitadas" unless variants.any?(&:active?)
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
    copy = self.class.new(
      name: "#{name} (copia)".first(150), description: description, price_cents: price_cents,
      retail_category: retail_category, product: product, featured: false, active: false,
      position: position
    )
    # Mismas variantes y precios, sin stock limitado ni referencias de importación.
    variants.each { |v| copy.variants.build(name: v.name, description: v.description, position: v.position, price_cents: v.price_cents, active: v.active, product_id: v.product_id) }
    copy
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

  def ensure_variant
    single_variant if variants.reject(&:marked_for_destruction?).empty?
  end

  def sync_catalog_price
    kept = variants.reject(&:marked_for_destruction?).sort_by { |v| [v.position.to_i, v.id || Float::INFINITY] }
    chosen = kept.select(&:active?).last || kept.last
    self.price_cents = chosen.price_cents if chosen&.price_cents
  end

  # Variantes: al menos una; con varias, todas con nombre y sin repetir. Los errores de precio de un
  # producto simple se muestran como "Precio ..." (igual que antes de las variantes).
  def variants_are_consistent
    kept = variants.reject(&:marked_for_destruction?)
    errors.add(:base, "El producto tiene que tener al menos una variante.") if kept.empty?
    if kept.size > 1
      errors.add(:base, "Con más de una variante, cada una necesita un nombre (ej.: 18 cm, 22 cm).") if kept.any? { |v| v.name.to_s.squish.empty? }
      names = kept.map { |v| v.name.to_s.squish.downcase }.reject(&:empty?)
      errors.add(:base, "Hay variantes con el mismo nombre.") if names.uniq.size != names.size
    end
    kept.each do |variant|
      next if variant.valid?

      prefix = kept.size > 1 ? "Variante “#{variant.label}”: " : ""
      variant.errors.each do |error|
        if kept.size == 1 && error.attribute == :price
          errors.add(:price, error.message)
        else
          errors.add(:base, "#{prefix}#{error.full_message}")
        end
      end
    end
    destroyed = variants.select(&:marked_for_destruction?)
    if destroyed.any? { |v| v.persisted? && v.retail_order_items.exists? }
      errors.add(:base, "Una variante con pedidos no se elimina: deshabilitala.")
    end
  end
end
