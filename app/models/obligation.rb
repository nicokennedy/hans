# Una deuda con un proveedor (o un gasto sin proveedor): nace de UNA compra o de UN gasto
# (source, único). Todo el cálculo de saldos vive acá: el saldo nunca se almacena, es
# amount_cents menos las imputaciones vigentes de pagos. Compras y gastos comparten esta
# lógica pero siguen diferenciados por `source_type` para los reportes.
class Obligation < ApplicationRecord
  DOCUMENT_TYPES = {
    "factura_a" => "Factura A", "factura_b" => "Factura B", "factura_c" => "Factura C",
    "remito" => "Remito", "ticket" => "Ticket", "recibo" => "Recibo",
    "boleta" => "Boleta de servicio", "sin_comprobante" => "Sin comprobante", "otro" => "Otro"
  }.freeze

  # Subconsulta con lo imputado a la obligación por pagos vigentes (no anulados).
  PAID_SQL = "COALESCE((SELECT SUM(a.amount_cents) FROM outgoing_payment_applications a WHERE a.obligation_id = obligations.id AND a.voided_at IS NULL), 0)".freeze

  belongs_to :supplier, optional: true
  belongs_to :source, polymorphic: true
  belongs_to :user, optional: true
  belongs_to :voided_by, class_name: "User", optional: true
  has_many :applications, class_name: "OutgoingPaymentApplication", dependent: :restrict_with_exception

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :accrual_on, presence: true
  validates :document_type, inclusion: { in: DOCUMENT_TYPES.keys }, allow_blank: true
  validates :document_number, length: { maximum: 60 }
  validates :void_reason, presence: true, if: :voided?
  validate :due_on_not_before_accrual
  validate :amount_not_below_applied, on: :update
  validate :supplier_fixed_once_paid, on: :update

  scope :active, -> { where(voided_at: nil) }
  scope :with_paid, -> { select("obligations.*, #{PAID_SQL} AS paid_cents_sql") }
  scope :outstanding, -> { active.where("obligations.amount_cents > #{PAID_SQL}") }
  scope :settled, -> { active.where("obligations.amount_cents <= #{PAID_SQL}") }
  scope :partially_paid, -> { outstanding.where("#{PAID_SQL} > 0") }
  scope :unpaid, -> { outstanding.where("#{PAID_SQL} = 0") }
  scope :purchases, -> { where(source_type: "Purchase") }
  scope :expenses, -> { where(source_type: "Expense") }
  # Más antiguas primero: vencimiento (sin vencimiento al final), luego fecha de compra/devengamiento.
  scope :oldest_first, -> { order(Arel.sql("obligations.due_on ASC NULLS LAST"), :accrual_on, :id) }

  def voided?
    voided_at.present?
  end

  def purchase?
    source_type == "Purchase"
  end

  def paid_cents
    has_attribute?(:paid_cents_sql) ? self[:paid_cents_sql].to_i : applications.active.sum(:amount_cents)
  end

  def balance_cents
    amount_cents - paid_cents
  end

  def status
    return :voided if voided?
    return :paid if balance_cents <= 0
    return :partial if paid_cents.positive?

    :pending
  end

  def status_label
    { voided: "Anulado", paid: "Pagado", partial: "Parcialmente pagado", pending: "Pendiente" }.fetch(status)
  end

  def overdue?(today = Date.current)
    !voided? && balance_cents.positive? && due_on.present? && due_on < today
  end

  def document_label
    [DOCUMENT_TYPES[document_type], document_number.presence].compact.join(" ").presence || "Sin comprobante"
  end

  private

  def due_on_not_before_accrual
    errors.add(:due_on, "no puede ser anterior a la fecha de la operación") if due_on && accrual_on && due_on < accrual_on
  end

  def amount_not_below_applied
    return unless amount_cents_changed?

    paid = applications.active.sum(:amount_cents)
    errors.add(:amount_cents, "no puede ser menor a lo ya pagado ($#{Finance::Money.format_pesos(paid)})") if amount_cents < paid
  end

  def supplier_fixed_once_paid
    return unless supplier_id_changed? && applications.active.exists?

    errors.add(:supplier_id, "no se puede cambiar: la obligación ya tiene pagos imputados")
  end
end
