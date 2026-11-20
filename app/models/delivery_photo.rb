# Foto del remito firmado de una parada (Repartos R4, decisión D9). El archivo va a Active
# Storage: en producción solo Cloudflare R2 (RetailCatalog::PhotoStorage); nunca se publica:
# se muestra a través de DeliveryPhotosController, solo a administración y al repartidor del
# recorrido. Pedido, cliente, repartidor y fecha salen de la parada y el recorrido.
class DeliveryPhoto < ApplicationRecord
  MAX_BYTES = 15.megabytes

  belongs_to :delivery_route, inverse_of: :photos
  belongs_to :delivery_stop
  belongs_to :taken_by, class_name: "User"
  has_one_attached :image

  validates :kind, inclusion: { in: %w[signed_receipt] }
  validate :image_is_a_photo

  private

  def image_is_a_photo
    return errors.add(:image, "falta") unless image.attached?

    errors.add(:image, "no es una foto") unless image.blob.content_type.to_s.start_with?("image/")
    errors.add(:image, "es demasiado grande (máximo 15 MB)") if image.blob.byte_size > MAX_BYTES
  end
end
