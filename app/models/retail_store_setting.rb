# Configuración de la tienda pública minorista (una sola fila), administrable desde
# Tienda Minorista → Tienda online:
#  - published: la tienda nace CERRADA. Mientras está cerrada el público ve "Próximamente" y solo
#    los administradores la recorren en vista previa (sin registrar pedidos). Publicarla es una
#    decisión explícita del equipo.
#  - whatsapp_number: número de HANS al que se dirige el mensaje del pedido (wa.me, solo dígitos con
#    código de país: 5492235275412).
#  - bank_transfer_details: datos para transferencia que ve el cliente que elige transferencia. Vacío
#    hasta que el equipo los cargue (no se inventan): mientras tanto se pasan por WhatsApp.
#  - Portada (hero): título, subtítulo y una foto opcional para campañas (Navidad, Pascuas...). Sin
#    foto, la portada arma sola la composición con fotos reales del catálogo. Título y subtítulo
#    vacíos usan los textos por defecto. La foto se sube con RetailCatalog::HeroImageUpload.
class RetailStoreSetting < ApplicationRecord
  DEFAULT_WHATSAPP = "5492235275412".freeze
  DEFAULT_HERO_TITLE = "Hecho a mano,\npara compartir.".freeze
  DEFAULT_HERO_SUBTITLE = "Tortas y dulces de HANS, preparados por encargo. Elegí online, retirá o recibilo en tu casa, y lo confirmamos juntos por WhatsApp.".freeze
  HERO_TITLE_MAX = 80
  HERO_SUBTITLE_MAX = 240
  # Encuadre de la foto de portada (qué parte se conserva al recortarla al marco).
  HERO_POSITIONS = { "center" => "Centro", "top" => "Arriba", "bottom" => "Abajo" }.freeze

  belongs_to :updated_by, class_name: "User", optional: true

  # Versiones optimizadas (WebP) de la foto de portada; nunca se sirve el original.
  #   hero    -> escritorio y pantallas grandes (hasta 1600 px de lado)
  #   hero_sm -> celulares (hasta 900 px de lado)
  has_one_attached :hero_image do |attachable|
    attachable.variant :hero, resize_to_limit: [1600, 1600], format: :webp, saver: { quality: 82 }
    attachable.variant :hero_sm, resize_to_limit: [900, 900], format: :webp, saver: { quality: 80 }
  end

  before_validation :normalize_fields

  validates :whatsapp_number, format: { with: /\A\d{10,15}\z/, message: "debe tener entre 10 y 15 dígitos, con código de país (ej. 5492235275412)" }
  validates :bank_transfer_details, length: { maximum: 1000 }, allow_nil: true
  validates :hero_title, length: { maximum: HERO_TITLE_MAX }, allow_nil: true
  validates :hero_subtitle, length: { maximum: HERO_SUBTITLE_MAX }, allow_nil: true
  validates :hero_image_alt, length: { maximum: 150 }, allow_nil: true
  validates :hero_image_position, inclusion: { in: HERO_POSITIONS.keys }

  # La fila de configuración; si no existe (base nueva o tests) la crea cerrada.
  def self.current
    first || create!(published: false, whatsapp_number: DEFAULT_WHATSAPP)
  rescue ActiveRecord::RecordNotUnique
    first!
  end

  def self.published?
    current.published?
  end

  # "+54 9 223 5275412"
  def whatsapp_display
    match = whatsapp_number.to_s.match(/\A549(\d{3})(\d+)\z/)
    match ? "+54 9 #{match[1]} #{match[2]}" : "+#{whatsapp_number}"
  end

  # Líneas del título de la portada (la segunda se muestra en itálica, como acento).
  def hero_title_lines
    (hero_title.presence || DEFAULT_HERO_TITLE).split("\n").map(&:strip).reject(&:blank?).first(2)
  end

  def hero_subtitle_text
    hero_subtitle.presence || DEFAULT_HERO_SUBTITLE
  end

  def hero_image?
    hero_image.attached?
  end

  private

  def normalize_fields
    self.whatsapp_number = whatsapp_number.to_s.gsub(/\D/, "")
    self.bank_transfer_details = bank_transfer_details.to_s.strip.presence
    # Título: hasta dos líneas (Enter separa la línea en itálica); sin espacios sobrantes.
    self.hero_title = hero_title.to_s.gsub("\r\n", "\n").split("\n").map(&:squish).reject(&:blank?).first(2).join("\n").presence
    self.hero_subtitle = hero_subtitle.to_s.squish.presence
    self.hero_image_alt = hero_image_alt.to_s.squish.presence
    self.hero_image_position = "center" unless HERO_POSITIONS.key?(hero_image_position.to_s)
  end
end
