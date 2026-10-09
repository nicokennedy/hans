class Supplier < ApplicationRecord
  # Nunca se borra un proveedor con historial: se desactiva (active: false).
  has_many :obligations, dependent: :restrict_with_error
  has_many :outgoing_payments, dependent: :restrict_with_error
  has_many :expense_recurrences, dependent: :restrict_with_error

  before_validation :normalize_fields

  validates :name, presence: true, length: { maximum: 200 }
  validates :tax_id, format: { with: /\A\d{2}-?\d{8}-?\d\z/, message: "no tiene un formato válido (11 dígitos)" }, allow_blank: true
  validates :tax_id, uniqueness: { case_sensitive: false, message: "ya está cargado en otro proveedor" }, allow_blank: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(Arel.sql("lower(suppliers.name)")) }
  scope :search, lambda { |query|
    next all if query.blank?

    term = "%#{sanitize_sql_like(query.to_s.strip)}%"
    where("suppliers.name ILIKE :t OR suppliers.tax_id ILIKE :t OR suppliers.email ILIKE :t OR suppliers.phone ILIKE :t", t: term)
  }

  def deletable?
    !obligations.exists? && !outgoing_payments.exists? && !expense_recurrences.exists?
  end

  # Saldos SIEMPRE calculados desde obligaciones y pagos reales.
  def pending_cents
    obligations.outstanding.with_paid.sum { |obligation| obligation.balance_cents }
  end

  def advance_cents
    outgoing_payments.active.sum { |payment| payment.unapplied_cents }
  end

  # Neto = deuda pendiente − anticipos disponibles (negativo = saldo a favor del negocio).
  def net_balance_cents
    pending_cents - advance_cents
  end

  private

  def normalize_fields
    %i[name tax_id email phone address].each { |field| self[field] = self[field].to_s.strip.presence }
    self.tax_id = tax_id&.delete("-") if tax_id
    self.notes = notes.to_s.strip.presence
  end
end
