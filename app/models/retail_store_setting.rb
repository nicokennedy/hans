# Configuración de la tienda pública minorista (una sola fila), administrable desde
# Tienda Minorista → Tienda online:
#  - published: la tienda nace CERRADA. Mientras está cerrada el público ve "Próximamente" y solo
#    los administradores la recorren en vista previa (sin registrar pedidos). Publicarla es una
#    decisión explícita del equipo.
#  - whatsapp_number: número de HANS al que se dirige el mensaje del pedido (wa.me, solo dígitos con
#    código de país: 5492235275412).
#  - bank_transfer_details: datos para transferencia que ve el cliente que elige transferencia. Vacío
#    hasta que el equipo los cargue (no se inventan): mientras tanto se pasan por WhatsApp.
class RetailStoreSetting < ApplicationRecord
  DEFAULT_WHATSAPP = "5492235275412".freeze

  belongs_to :updated_by, class_name: "User", optional: true

  before_validation :normalize_fields

  validates :whatsapp_number, format: { with: /\A\d{10,15}\z/, message: "debe tener entre 10 y 15 dígitos, con código de país (ej. 5492235275412)" }
  validates :bank_transfer_details, length: { maximum: 1000 }, allow_nil: true

  # La fila de configuración; si no existe (base nueva o tests) la crea cerrada.
  def self.current
    first || create!(published: false, whatsapp_number: DEFAULT_WHATSAPP)
  rescue ActiveRecord::RecordNotUnique
    first!
  end

  def self.published?
    current.published?
  end

  # "+54 9 223 5275412"
  def whatsapp_display
    match = whatsapp_number.to_s.match(/\A549(\d{3})(\d+)\z/)
    match ? "+54 9 #{match[1]} #{match[2]}" : "+#{whatsapp_number}"
  end

  private

  def normalize_fields
    self.whatsapp_number = whatsapp_number.to_s.gsub(/\D/, "")
    self.bank_transfer_details = bank_transfer_details.to_s.strip.presence
  end
end
