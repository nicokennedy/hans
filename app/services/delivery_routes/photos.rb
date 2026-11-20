module DeliveryRoutes
  # Foto del remito firmado (R4, D9). Se sube en un pedido aparte de la entrega y del cobro:
  # si falla, no se pierde nada y la parada queda "Falta la foto del remito" para reintentar.
  # En producción solo se aceptan fotos si Active Storage usa Cloudflare R2 (el disco de Heroku
  # se borra): misma regla que la tienda minorista (RetailCatalog::PhotoStorage).
  # El repartidor puede subirla hasta que administración confirma el cierre.
  class Photos
    Result = Struct.new(:photo, :errors, :already, keyword_init: true) do
      def ok?
        errors.blank?
      end
    end

    def initialize(route, user)
      @route = route
      @user = user
    end

    def attach(stop, file, request_token:)
      token = request_token.to_s.strip
      return failure("Falta el identificador del formulario. Volvé a intentar.") if token.blank?
      if (existing = DeliveryPhoto.find_by(request_token: token))
        return Result.new(photo: existing, errors: [], already: true)
      end
      return failure(denied) if (denied = access_error)
      return failure("Las fotos no están disponibles en este momento. Quedó pendiente: avisale a administración.") unless RetailCatalog::PhotoStorage.enabled?
      return failure("No llegó ninguna foto. Probá de nuevo.") unless file.respond_to?(:content_type)

      stop = @route.stops.active.find(stop.id)
      photo = nil
      DeliveryPhoto.transaction do
        photo = @route.photos.new(delivery_stop: stop, request_token: token, taken_by: @user)
        photo.image.attach(io: file, filename: "remito-#{@route.id}-#{stop.id}-#{Time.current.strftime('%Y%m%d%H%M%S')}#{File.extname(file.original_filename.to_s).downcase.presence || '.jpg'}",
                           content_type: file.content_type)
        photo.save!
        Events.record(@route, @user, "photo_added", stop: stop, photo_id: photo.id, summary: "#{@user.display_name} subió la foto del remito de #{stop.display_name}.")
      end
      Result.new(photo: photo, errors: [], already: false)
    rescue ActiveRecord::RecordInvalid => e
      failure("La foto no se pudo guardar (#{e.record.errors.full_messages.to_sentence}). Quedó pendiente.")
    rescue ActiveRecord::RecordNotUnique
      existing = DeliveryPhoto.find_by(request_token: token)
      existing ? Result.new(photo: existing, errors: [], already: true) : failure("La foto no se pudo guardar. Quedó pendiente.")
    rescue StandardError => e
      Rails.logger.error("[reparto] foto de remito: #{e.class}: #{e.message}")
      failure("La foto no se pudo guardar. Quedó pendiente: podés volver a intentarlo desde la parada.")
    end

    # "El cliente no quiso firmar": excepción justificada (D9), visible para administración.
    def no_signature(stop)
      return failure(denied) if (denied = access_error)

      DeliveryStop.transaction do
        stop = @route.stops.active.lock.find(stop.id)
        unless stop.receipt_exception == "no_signature"
          stop.update!(receipt_exception: "no_signature", receipt_exception_at: Time.current, receipt_exception_by: @user)
          Events.record(@route, @user, "receipt_exception", stop: stop, summary: "#{@user.display_name} registró que #{stop.display_name} no quiso firmar el remito.")
        end
      end
      Result.new(errors: [], already: false)
    end

    private

    def access_error
      if @user&.admin? || (@user&.driver? && @route.driver_id == @user.id)
        @route.confirmed? ? "La rendición ya está cerrada." : nil
      else
        "No tenés permiso para este recorrido."
      end
    end

    def failure(message)
      Result.new(errors: [message], already: false)
    end
  end
end
