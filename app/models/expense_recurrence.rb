# Gasto que se repite. Cada ocurrencia es un Expense independiente (con su obligación,
# vencimiento y estado de pago); la clave única (recurrencia, fecha) evita duplicados
# aunque el proceso se ejecute varias veces.
class ExpenseRecurrence < ApplicationRecord
  FREQUENCIES = { "daily" => "Diaria", "weekly" => "Semanal", "monthly" => "Mensual" }.freeze

  belongs_to :supplier, optional: true
  belongs_to :expense_category
  belongs_to :user, optional: true
  has_many :expenses, dependent: :restrict_with_error

  validates :frequency, inclusion: { in: FREQUENCIES.keys }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :starts_on, presence: true
  validates :max_occurrences, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :due_days, numericality: { only_integer: true, greater_than_or_equal_to: 0, less_than_or_equal_to: 365 }
  validates :document_type, inclusion: { in: Obligation::DOCUMENT_TYPES.keys }, allow_blank: true
  validate :ends_on_not_before_start

  scope :active, -> { where(active: true) }

  def frequency_label
    FREQUENCIES[frequency]
  end

  # Fechas de ocurrencia hasta `through` (inclusive), respetando fin por fecha o cantidad.
  # La mensual se calcula siempre desde la fecha de inicio (31/01 -> 28/02 -> 31/03).
  def occurrence_dates(through)
    dates = []
    index = 0

    loop do
      break if max_occurrences && index >= max_occurrences

      date = case frequency
             when "daily" then starts_on + index
             when "weekly" then starts_on + (7 * index)
             else starts_on >> index
             end
      break if date > through || (ends_on && date > ends_on)

      dates << date
      index += 1
    end

    dates
  end

  def finished?(today = Date.current)
    return true unless active?
    return true if ends_on && ends_on < today

    max_occurrences.present? && expenses.count >= max_occurrences
  end

  private

  def ends_on_not_before_start
    errors.add(:ends_on, "no puede ser anterior a la fecha de inicio") if ends_on && starts_on && ends_on < starts_on
  end
end
