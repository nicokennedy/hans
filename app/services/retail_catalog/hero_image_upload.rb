module RetailCatalog
  # Foto de portada de la tienda (RetailStoreSetting#hero_image): subir, reemplazar y quitar.
  # Mismo almacenamiento y mismos controles que las fotos del catálogo (RetailCatalog::PhotoUpload):
  # el tipo se valida por el contenido (JPEG, PNG o WebP) y en producción solo se acepta si el
  # almacenamiento es Cloudflare R2. Admite archivos algo más grandes (fotos de campaña tomadas con
  # el celular): la tienda siempre sirve versiones optimizadas.
  module HeroImageUpload
    MAX_BYTES = 10.megabytes

    Result = Struct.new(:ok, :error, keyword_init: true) do
      def ok?
        ok
      end
    end

    module_function

    # Reemplazar es lo mismo que subir: la foto anterior se borra del almacenamiento al adjuntar la nueva.
    def attach(setting:, file:)
      return Result.new(ok: false, error: "Elegí una imagen.") if file.blank?
      unless PhotoStorage.enabled?
        return Result.new(ok: false, error: "Las fotos todavía no están habilitadas: falta conectar el almacenamiento (Cloudflare R2).")
      end

      name = File.basename(file.original_filename.to_s).presence || "archivo"
      return Result.new(ok: false, error: "#{name}: supera el máximo de 10 MB.") if file.size.to_i > MAX_BYTES

      bytes = file.read.to_s.b
      return Result.new(ok: false, error: "#{name}: supera el máximo de 10 MB.") if bytes.bytesize > MAX_BYTES

      content_type = PhotoUpload.sniff_image_type(bytes)
      return Result.new(ok: false, error: "#{name}: no es una imagen JPEG, PNG o WebP válida.") unless content_type

      extension = { "image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp" }.fetch(content_type)
      base = File.basename(name, ".*").gsub(/[^\w\- ]/, "_").strip.first(80).presence || "portada"
      setting.hero_image.attach(io: StringIO.new(bytes), filename: "#{base}#{extension}", content_type: content_type, identify: false)
      Result.new(ok: true)
    end

    def remove(setting:)
      setting.hero_image.purge_later if setting.hero_image.attached?
      Result.new(ok: true)
    end
  end
end
