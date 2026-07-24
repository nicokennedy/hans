module Notifications
  # Centraliza el número de WhatsApp del obrador y la construcción de links
  # `wa.me`. El número se lee de ENV["WHATSAPP_OBRADOR_NUMBER"] (documentado
  # en el README) — nunca hardcodeado en vistas ni controllers.
  class WhatsappLink
    def self.number
      ENV["WHATSAPP_OBRADOR_NUMBER"].presence
    end

    def self.configured?
      number.present?
    end

    # Devuelve nil (en vez de un link roto) si la variable de entorno no
    # está configurada, para que las vistas puedan ocultar el botón.
    def self.build(text)
      return nil unless configured?

      "https://wa.me/#{number}?text=#{ERB::Util.url_encode(text)}"
    end
  end
end
