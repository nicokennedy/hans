# Gasto general (alquiler, servicios, sueldos…). Genera UNA obligación. Puede ser una
# ocurrencia de un gasto recurrente.
class Expense < ApplicationRecord
  include HasAdministrationAttachments

  belongs_to :expense_category
  belongs_to :expense_recurrence, optional: true
  has_one :obligation, as: :source, dependent: :restrict_with_exception

  validates :occurrence_on, presence: true, if: :expense_recurrence_id?
end
