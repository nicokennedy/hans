# Gastos recurrentes (diarios, semanales, mensuales). Cada ocurrencia es un gasto
# independiente con su obligación; nada se marca como pagado automáticamente.
class Admin::Administration::ExpenseRecurrencesController < Admin::Administration::BaseController
  include FinanceParams

  before_action :set_recurrence, only: [:edit, :update, :deactivate]

  def index
    @recurrences = ExpenseRecurrence.includes(:expense_category, :supplier).order(active: :desc, starts_on: :desc)
    @generated = Expense.where.not(expense_recurrence_id: nil).group(:expense_recurrence_id).count
  end

  def new
    @recurrence = ExpenseRecurrence.new(frequency: "monthly", starts_on: Date.current, due_days: 10)
    prepare_form
  end

  def create
    @recurrence = ExpenseRecurrence.new(user: current_user)
    save_and_respond(@recurrence, creating: true)
  end

  def edit
    prepare_form
  end

  def update
    save_and_respond(@recurrence, creating: false)
  end

  def deactivate
    @recurrence.update!(active: false)
    redirect_to admin_administration_expense_recurrences_path, notice: "Recurrencia desactivada. Los gastos ya generados se conservan."
  end

  def generate
    created = Finance::GenerateRecurringExpenses.call
    redirect_to admin_administration_expense_recurrences_path, notice: created.zero? ? "No había ocurrencias nuevas para generar." : "Se generaron #{created} #{created == 1 ? 'gasto' : 'gastos'}."
  end

  private

  def set_recurrence
    @recurrence = ExpenseRecurrence.find(params[:id])
  end

  def prepare_form
    @suppliers = Supplier.where(id: [*Supplier.active.pluck(:id), @recurrence&.supplier_id].compact).ordered
    @categories = ExpenseCategory.where(id: [*ExpenseCategory.active.pluck(:id), @recurrence&.expense_category_id].compact).ordered
  end

  def save_and_respond(recurrence, creating:)
    permitted = params.require(:expense_recurrence).permit(:expense_category_id, :supplier_id, :frequency, :starts_on, :ends_on, :max_occurrences, :due_days, :document_type, :notes, :active)
    amount, amount_error = money_param(params.dig(:expense_recurrence, :amount), "El importe")
    recurrence.assign_attributes(permitted.merge(supplier_id: permitted[:supplier_id].presence, ends_on: permitted[:ends_on].presence, max_occurrences: permitted[:max_occurrences].presence, document_type: permitted[:document_type].presence))
    recurrence.amount_cents = amount if amount
    recurrence.errors.add(:amount_cents, amount_error) if amount_error

    if amount_error.nil? && amount && recurrence.save
      created = creating ? Finance::GenerateRecurringExpenses.call(recurrence: recurrence) : 0
      notice = creating ? "Recurrencia creada#{created.positive? ? " y se generaron #{created} #{created == 1 ? 'gasto' : 'gastos'}" : ''}." : "Recurrencia actualizada (no cambia los gastos ya generados)."
      redirect_to admin_administration_expense_recurrences_path, notice: notice
    else
      recurrence.errors.add(:amount_cents, "es obligatorio") if amount.nil? && amount_error.nil?
      prepare_form
      render(creating ? :new : :edit, status: :unprocessable_entity)
    end
  end
end
