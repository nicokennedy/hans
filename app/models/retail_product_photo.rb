# Fotografía de un producto del catálogo minorista. Un producto puede tener varias; una sola es
# la principal (índice único parcial) y es la que va en las tarjetas del catálogo; las demás se
# muestran en la galería del detalle, por orden. El archivo vive en Active Storage (Cloudflare R2
# en producción): nunca en PostgreSQL ni en el disco de Heroku. Las subidas pasan por
# RetailCatalog::PhotoUpload (tipo real, tamaño, duplicados).
class RetailProductPhoto < ApplicationRecord
  MAX_BYTES = 5.megabytes
  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze

  belongs_to :retail_product, inverse_of: :photos

  # Versiones optimizadas (WebP), generadas la primera vez que se piden: nunca se sirven los
  # originales de varios MB en el catálogo.
  #   thumb  -> miniatura del administrador (160x160, recortada)
  #   card   -> tarjeta del catálogo (600x600, recortada; nítida en celulares 2x)
  #   detail -> galería del detalle (hasta 1200 px de lado, sin recortar)
  has_one_attached :image do |attachable|
    attachable.variant :thumb, resize_to_fill: [160, 160], format: :webp, saver: { quality: 78 }
    attachable.variant :card, resize_to_fill: [600, 600], format: :webp, saver: { quality: 80 }
    attachable.variant :detail, resize_to_limit: [1200, 1200], format: :webp, saver: { quality: 82 }
  end

  validates :checksum, presence: true, uniqueness: { scope: :retail_product_id, message: "esa imagen ya está cargada en este producto" }
  validate :image_must_be_attached

  scope :secondary, -> { where(primary: false) }

  private

  def image_must_be_attached
    errors.add(:image, "es obligatoria") unless image.attached?
  end
end
