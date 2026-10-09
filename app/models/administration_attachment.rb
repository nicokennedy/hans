require "digest"

# Archivo adjunto guardado en la base (ver la migración: el disco de Heroku es efímero y
# no hay almacenamiento externo configurado). Se descarga solo a través de un
# controlador de administración. La columna `data` nunca se carga en los listados.
class AdministrationAttachment < ApplicationRecord
  MAX_BYTES = 3.megabytes
  ALLOWED_TYPES = {
    "application/pdf" => ".pdf",
    "image/jpeg" => ".jpg",
    "image/png" => ".png",
    "image/webp" => ".webp"
  }.freeze

  belongs_to :owner, polymorphic: true
  belongs_to :user, optional: true

  scope :without_data, -> { select(column_names - ["data"]) }

  validates :filename, :content_type, :checksum, presence: true
  validates :content_type, inclusion: { in: ALLOWED_TYPES.keys, message: "no es un tipo permitido (PDF, JPG, PNG o WEBP)" }
  validates :byte_size, numericality: { less_than_or_equal_to: MAX_BYTES, message: "supera el máximo de 3 MB" }
  validates :data, presence: true

  # Crea el adjunto a partir de un archivo subido (ActionDispatch::Http::UploadedFile).
  def self.build_from_upload(owner, upload, user: nil)
    bytes = upload.read.to_s.b
    new(
      owner: owner, user: user, data: bytes, byte_size: bytes.bytesize,
      filename: File.basename(upload.original_filename.to_s).gsub(/[^\w.\- ]/, "_").truncate(120, omission: ""),
      content_type: sniff_type(bytes) || "application/octet-stream", checksum: Digest::SHA256.hexdigest(bytes)
    )
  end

  # El tipo se deduce de los primeros bytes (no solo de lo que declara el navegador).
  def self.sniff_type(bytes)
    head = bytes.byteslice(0, 12).to_s.b
    return "application/pdf" if head.start_with?("%PDF")
    return "image/png" if head.start_with?("\x89PNG".b)
    return "image/jpeg" if head.start_with?("\xFF\xD8\xFF".b)
    return "image/webp" if head.start_with?("RIFF".b) && head.byteslice(8, 4) == "WEBP".b

    nil
  end
end
