# app/models/customer.rb
class Customer < ApplicationRecord
  has_many :users, dependent: :destroy
  has_many :orders, dependent: :restrict_with_error
  has_many :customer_payments, dependent: :restrict_with_error
  # Productos restringidos a este cliente (ver Product#customer_visibility). Solo son permisos de pedido.
  has_many :product_customer_accesses, dependent: :destroy
  has_many :exclusive_products, through: :product_customer_accesses, source: :product

  validates :name, presence: true
  validates :email, presence: true, uniqueness: true, allow_blank: true

  scope :active, -> { where(active: true) }

  SEARCH_MAX_LENGTH = 100
  ACCENTED = "áàäâãéèëêíìïîóòöôõúùüûñçÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇ".freeze
  UNACCENTED = "aaaaaeeeeiiiiooooouuuuncAAAAAEEEEIIIIOOOOOUUUUNC".freeze

  # Buscador del listado de clientes (Admin → Clientes). Coincidencia parcial, sin
  # mayúsculas/minúsculas ni tildes, sobre nombre, contacto, email comercial, teléfono
  # y email de acceso. Varias palabras se buscan todas, en cualquier campo. Se resuelve
  # en SQL con translate() (sin extensiones), así busca en toda la base.
  def self.search(query)
    terms = normalize_search(query).split.uniq
    return all if terms.empty?

    terms.reduce(all) do |scope, term|
      pattern = "%#{sanitize_sql_like(term)}%"
      digits = term.gsub(/\D/, "")
      conditions = %w[customers.name customers.contact_name customers.email customers.phone].map { |column| "#{folded(column)} LIKE :pattern" }
      conditions << "EXISTS (SELECT 1 FROM users WHERE users.customer_id = customers.id AND #{folded('users.email')} LIKE :pattern)"
      # "1155 123" o "11-55" encuentran "+54 11 5512-3456": el teléfono se compara también solo con dígitos.
      conditions << "regexp_replace(COALESCE(customers.phone, ''), '[^0-9]', '', 'g') LIKE :digits" if digits.length >= 3
      scope.where(conditions.join(" OR "), pattern: pattern, digits: "%#{digits}%")
    end
  end

  def self.normalize_search(query)
    I18n.transliterate(query.to_s.first(SEARCH_MAX_LENGTH).unicode_normalize(:nfc)).downcase.squish
  end

  def self.folded(column)
    "lower(translate(COALESCE(#{column}, ''), '#{ACCENTED}', '#{UNACCENTED}'))"
  end
  private_class_method :folded
end