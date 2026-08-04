module Notifications
  # Centraliza la configuración VAPID leída de variables de entorno — nunca
  # hardcodeada en el repo. Solo la clave pública puede llegar al navegador
  # (vía el endpoint de configuración); la privada nunca sale de acá.
  class WebPushVapid
    def self.public_key
      ENV["WEB_PUSH_VAPID_PUBLIC_KEY"].presence
    end

    def self.private_key
      ENV["WEB_PUSH_VAPID_PRIVATE_KEY"].presence
    end

    def self.subject
      ENV["WEB_PUSH_VAPID_SUBJECT"].presence
    end

    def self.configured?
      public_key.present? && private_key.present? && subject.present?
    end

    def self.vapid_options
      { subject: subject, public_key: public_key, private_key: private_key }
    end
  end
end
