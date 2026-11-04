require "digest"

module RetailCatalog
  # Subida y reemplazo de fotos de un producto minorista. Cada archivo se valida por su contenido
  # (los primeros bytes, no la extensión ni lo que declara el navegador): solo JPEG, PNG o WebP, de
  # hasta 5 MB, y sin repetir una imagen ya cargada en el mismo producto. Los archivos válidos se
  # guardan aunque otros del mismo envío fallen; cada error dice qué archivo y por qué.
  # La primera foto de un producto queda como principal.
  class PhotoUpload
    Result = Struct.new(:saved, :errors, keyword_init: true) do
      def ok?
        errors.empty?
      end
    end

    def self.add(product:, files:)
      new(product).add(Array(files))
    end

    def self.replace(photo:, file:)
      new(photo.retail_product).replace(photo, file)
    end

    def initialize(product)
      @product = product
    end

    def add(files)
      files = files.reject(&:blank?)
      return Result.new(saved: [], errors: ["Elegí al menos una imagen."]) if files.empty?
      return Result.new(saved: [], errors: [unavailable_message]) unless PhotoStorage.enabled?

      saved = []
      errors = []
      files.each do |file|
        checked = inspect_file(file)
        next errors << checked[:error] if checked[:error]

        photo = nil
        RetailProductPhoto.transaction do
          @product.lock!
          next errors << "#{checked[:name]}: esa imagen ya está cargada en este producto." if @product.photos.exists?(checksum: checked[:checksum])

          photo = @product.photos.build(checksum: checked[:checksum], position: next_position, primary: !@product.photos.where(primary: true).exists?)
          photo.image.attach(io: StringIO.new(checked[:bytes]), filename: checked[:filename], content_type: checked[:content_type], identify: false)
          photo.save!
        end
        saved << photo if photo&.persisted?
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        errors << "#{checked[:name]}: #{e.is_a?(ActiveRecord::RecordInvalid) ? e.record.errors.full_messages.to_sentence : 'esa imagen ya está cargada en este producto.'}"
      end

      Result.new(saved: saved, errors: errors)
    end

    # Cambia el archivo de una foto conservando su lugar (principal u orden).
    def replace(photo, file)
      return Result.new(saved: [], errors: ["Elegí una imagen."]) if file.blank?
      return Result.new(saved: [], errors: [unavailable_message]) unless PhotoStorage.enabled?

      checked = inspect_file(file)
      return Result.new(saved: [], errors: [checked[:error]]) if checked[:error]
      if @product.photos.where.not(id: photo.id).exists?(checksum: checked[:checksum])
        return Result.new(saved: [], errors: ["#{checked[:name]}: esa imagen ya está cargada en este producto."])
      end

      RetailProductPhoto.transaction do
        photo.lock!
        photo.image.attach(io: StringIO.new(checked[:bytes]), filename: checked[:filename], content_type: checked[:content_type], identify: false)
        photo.update!(checksum: checked[:checksum])
      end
      Result.new(saved: [photo], errors: [])
    rescue ActiveRecord::RecordInvalid => e
      Result.new(saved: [], errors: e.record.errors.full_messages)
    end

    private

    def inspect_file(file)
      name = File.basename(file.original_filename.to_s).presence || "archivo"
      return { name: name, error: "#{name}: supera el máximo de 5 MB." } if file.size.to_i > RetailProductPhoto::MAX_BYTES

      bytes = file.read.to_s.b
      return { name: name, error: "#{name}: supera el máximo de 5 MB." } if bytes.bytesize > RetailProductPhoto::MAX_BYTES

      content_type = self.class.sniff_image_type(bytes)
      return { name: name, error: "#{name}: no es una imagen JPEG, PNG o WebP válida." } unless content_type

      extension = { "image/jpeg" => ".jpg", "image/png" => ".png", "image/webp" => ".webp" }.fetch(content_type)
      base = File.basename(name, ".*").gsub(/[^\w\- ]/, "_").strip.first(80).presence || "foto"
      { name: name, bytes: bytes, content_type: content_type, checksum: Digest::SHA256.hexdigest(bytes), filename: "#{base}#{extension}" }
    end

    # Tipo real por los primeros bytes (mismo criterio que AdministrationAttachment.sniff_type),
    # solo para imágenes, y con un mínimo de cabecera: un archivo vacío o truncado no pasa.
    def self.sniff_image_type(bytes)
      return nil if bytes.bytesize < 16

      type = AdministrationAttachment.sniff_type(bytes)
      RetailProductPhoto::CONTENT_TYPES.include?(type) ? type : nil
    end

    def next_position
      (@product.photos.maximum(:position) || 0) + 1
    end

    def unavailable_message
      "Las fotos todavía no están habilitadas: falta conectar el almacenamiento (Cloudflare R2)."
    end
  end
end
