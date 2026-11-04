module RetailCatalog
  # Dónde viven las fotos del catálogo minorista y si se pueden subir.
  #
  # - Desarrollo y test: disco local (storage/ y tmp/storage), siempre habilitado.
  # - Producción: SOLO Cloudflare R2. El disco de Heroku se borra en cada deploy/reinicio, así que
  #   si el servicio activo no es R2 la subida queda bloqueada (nunca se aceptan fotos que se
  #   perderían). R2 se activa con las variables R2_* completas y RETAIL_PHOTOS_ENABLED=true
  #   (ver config/environments/production.rb y docs/TIENDA_MINORISTA.md).
  module PhotoStorage
    R2_SERVICE = :cloudflare_r2
    REQUIRED_ENV = %w[R2_ACCOUNT_ID R2_BUCKET R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY].freeze

    module_function

    def enabled?
      return true unless Rails.env.production?

      current_service_name == R2_SERVICE
    end

    def current_service_name
      ActiveStorage::Blob.service&.name&.to_sym
    end

    def missing_env
      REQUIRED_ENV.reject { |key| ENV[key].present? }
    end

    # Qué falta para habilitar las fotos en producción (para mostrarlo en el admin).
    def blockers
      return [] if enabled?

      issues = []
      issues << "Faltan variables de Cloudflare R2: #{missing_env.join(', ')}" if missing_env.any?
      issues << "Falta habilitarlas con RETAIL_PHOTOS_ENABLED=true después de verificar el bucket" if missing_env.empty?
      issues
    end

    # Prueba real contra R2 (sube, lee y borra un objeto chico). La usa
    # bin/rails retail_catalog:check_storage ANTES de habilitar las fotos; no toca la base.
    def check_r2!
      raise ArgumentError, "Faltan variables: #{missing_env.join(', ')}" if missing_env.any?

      service = ActiveStorage::Blob.services.fetch(R2_SERVICE) # lo arma desde storage.yml aunque no sea el activo
      key = "hans-check/#{SecureRandom.hex(8)}"
      body = "HANS #{Time.current.iso8601}"
      service.upload(key, StringIO.new(body), checksum: OpenSSL::Digest::MD5.base64digest(body))
      read_back = service.download(key)
      service.delete(key)
      raise "El contenido leído no coincide" unless read_back == body

      true
    end
  end
end
