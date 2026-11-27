module DeliveryRoutes
  class OptionalEvidence
    TYPES = %w[image/jpeg image/png image/webp image/heic image/heif].freeze

    def self.attach(record, file, user)
      return true if file.blank?
      return false unless file.respond_to?(:tempfile) && RetailCatalog::PhotoStorage.enabled?
      return false if file.size > DeliveryPhoto::MAX_BYTES
      type = Marcel::MimeType.for(file.tempfile)
      return false unless TYPES.include?(type) || (record.is_a?(DeliveryIncome) && type == "application/pdf")

      file.tempfile.rewind

      blob = ActiveStorage::Blob.create_and_upload!(io: file.tempfile, filename: file.original_filename, content_type: type, identify: false)
      attached = record.delivery_route.with_lock do
        next false if Access.money_error(record.delivery_route, user) || record.reload.voided?

        record.evidence.attach(blob)
        record.evidence.attached?
      end
      blob.purge_later unless attached
      attached
    rescue StandardError => error
      Rails.logger.warn("[reparto] comprobante opcional: #{error.class}")
      blob&.purge_later
      false
    end
  end
end
