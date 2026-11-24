module RetailCatalog
  # Logo del encabezado de la tienda pública (RetailStoreSetting#logo): subir, reemplazar y quitar.
  # Mismo almacenamiento y mismos controles que las fotos del catálogo (RetailCatalog::PhotoUpload y
  # PhotoStorage): el tipo se valida por el contenido (los primeros bytes) y en producción solo se
  # acepta si el almacenamiento es Cloudflare R2.
  #
  # Solo PNG y WebP, que admiten fondo transparente (un JPEG no lo admite). No se acepta SVG: puede
  # traer código. La tienda sirve una versión WebP optimizada que conserva la transparencia y las
  # proporciones (RetailStoreSetting::LOGO_VARIANT).
  module LogoUpload
    MAX_BYTES = 5.megabytes
    CONTENT_TYPES = { "image/png" => ".png", "image/webp" => ".webp" }.freeze

    Result = Struct.new(:ok, :error, keyword_init: true) do
      def ok?
        ok
      end
    end

    module_function

    # Reemplazar es lo mismo que subir: el logo anterior se borra del almacenamiento al adjuntar el nuevo.
    def attach(setting:, file:)
      return failure("Elegí una imagen PNG o WebP.") if file.blank? || !file.respond_to?(:read)
      return failure("Las imágenes todavía no están habilitadas: falta conectar el almacenamiento (Cloudflare R2).") unless PhotoStorage.enabled?

      name = File.basename(file.original_filename.to_s).presence || "archivo"
      return failure("#{name}: supera el máximo de 5 MB.") if file.size.to_i > MAX_BYTES

      bytes = file.read.to_s.b
      return failure("#{name}: supera el máximo de 5 MB.") if bytes.bytesize > MAX_BYTES

      content_type = PhotoUpload.sniff_image_type(bytes)
      unless CONTENT_TYPES.key?(content_type)
        return failure("#{name}: el logo tiene que ser una imagen PNG o WebP (admiten fondo transparente).")
      end

      base = File.basename(name, ".*").gsub(/[^\w\- ]/, "_").strip.first(80).presence || "logo"
      setting.logo.attach(io: StringIO.new(bytes), filename: "#{base}#{CONTENT_TYPES.fetch(content_type)}", content_type: content_type, identify: false)
      Result.new(ok: true)
    end

    def remove(setting:)
      setting.logo.purge_later if setting.logo.attached?
      Result.new(ok: true)
    end

    def failure(message)
      Result.new(ok: false, error: message)
    end
  end
end
