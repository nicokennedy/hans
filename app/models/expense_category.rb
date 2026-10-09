class ExpenseCategory < ApplicationRecord
  has_many :expenses, dependent: :restrict_with_error
  has_many :expense_recurrences, dependent: :restrict_with_error

  before_validation { self.name = name.to_s.strip }

  validates :name, presence: true, length: { maximum: 100 }
  validates :name, uniqueness: { case_sensitive: false, message: "ya existe" }

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:position, Arel.sql("lower(expense_categories.name)")) }

  def deletable?
    !expenses.exists? && !expense_recurrences.exists?
  end
end
