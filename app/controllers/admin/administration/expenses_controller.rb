# Gastos generales. En esta etapa NO tocan stock, materias primas, recetas ni costos.
class Admin::Administration::ExpensesController < Admin::Administration::BaseController
  include FinanceParams

  before_action :set_obligation, only: [:show, :edit, :update, :destroy, :void]

  def index
    begin
      Finance::GenerateRecurringExpenses.call
    rescue StandardError => e
      Rails.logger.error("No se pudieron generar los gastos recurrentes: #{e.message}")
    end

    @filters = list_filters
    scope = filtered_obligations
    respond_to do |format|
      format.html do
        @obligations = paginate(scope.order(accrual_on: :desc, id: :desc)).with_paid.includes(:supplier, source: :expense_category)
        @totals = { amount: scope.sum(:amount_cents), balance: scope.active.sum("obligations.amount_cents - #{Obligation::PAID_SQL}") }
        @categories = ExpenseCategory.ordered
      end
      format.csv do
        send_data Finance::CsvExport.expenses(scope.with_paid.includes(:supplier, source: :expense_category).order(accrual_on: :desc, id: :desc)), filename: "gastos-#{Date.current.iso8601}.csv", type: "text/csv; charset=utf-8", disposition: "attachment"
      end
    end
  end

  def export
    redirect_to admin_administration_expenses_path(request.query_parameters.symbolize_keys.merge(format: :csv))
  end

  def show
    @expense = @obligation.source
    @applications = @obligation.applications.includes(:outgoing_payment).order(:created_at)
  end

  def new
    @form = { accrual_on: Date.current.iso8601 }
    prepare_form
  end

  def create
    save_and_respond(nil)
  end

  def edit
    @expense = @obligation.source
    @form = { supplier_id: @obligation.supplier_id, expense_category_id: @expense.expense_category_id, amount: Finance::Money.format_pesos(@obligation.amount_cents), accrual_on: @obligation.accrual_on.iso8601,
              due_on: @obligation.due_on&.iso8601, document_type: @obligation.document_type, document_number: @obligation.document_number, notes: @obligation.notes }
    prepare_form
  end

  def update
    save_and_respond(@obligation.source)
  end

  def destroy
    result = Finance::DestroySource.call(@obligation.source)
    if result.ok?
      redirect_to admin_administration_expenses_path, notice: "Gasto eliminado."
    else
      redirect_to admin_administration_expense_path(@obligation), alert: result.errors.join(" ")
    end
  end

  def void
    result = Finance::VoidObligation.call(obligation: @obligation, user: current_user, reason: params[:reason])
    redirect_to admin_administration_expense_path(@obligation), result.ok? ? { notice: "Gasto anulado. El registro se conserva." } : { alert: result.errors.join(" ") }
  end

  private

  def set_obligation
    @obligation = Obligation.expenses.find(params[:id])
  end

  def prepare_form
    @suppliers = Supplier.where(id: [*Supplier.active.pluck(:id), @obligation&.supplier_id].compact).ordered
    @categories = ExpenseCategory.where(id: [*ExpenseCategory.active.pluck(:id), @obligation&.source&.expense_category_id].compact).ordered
    @request_token = params[:request_token].presence || SecureRandom.uuid
  end

  def save_and_respond(expense)
    amount, e1 = money_param(params[:amount], "El importe")
    accrual_on, e2 = date_param(params[:accrual_on], "La fecha de registro", required: true)
    due_on, e3 = date_param(params[:due_on], "La fecha de vencimiento")
    pay_now, pay_errors = expense ? [nil, []] : parse_pay_now
    upload = upload_param
    errors = [e1, e2, e3].compact + pay_errors + attachment_errors(upload)
    errors << "Indicá el importe del gasto." if amount.nil? && e1.nil?

    result = if errors.empty?
      Finance::SaveExpense.call(
        user: current_user, expense: expense, upload: upload, pay_now: pay_now,
        attributes: { supplier_id: params[:supplier_id].presence, expense_category_id: params[:expense_category_id], amount_cents: amount, accrual_on: accrual_on, due_on: due_on,
                      document_type: params[:document_type].presence, document_number: params[:document_number].to_s.strip.presence, notes: params[:notes].to_s.strip.presence }
      )
    else
      Finance::Result.new(errors: errors)
    end

    if result.ok?
      redirect_to admin_administration_expense_path(result.record.obligation), notice: expense ? "Gasto actualizado." : "Gasto registrado."
    else
      @errors = result.errors
      @expense = expense
      @obligation = expense&.obligation
      @form = params.permit(:supplier_id, :expense_category_id, :amount, :accrual_on, :due_on, :document_type, :document_number, :notes, :pay_now, :pay_amount, :pay_method, :pay_reference, :pay_paid_on).to_h.symbolize_keys
      prepare_form
      render(expense ? :edit : :new, status: :unprocessable_entity)
    end
  end

  def list_filters
    {
      from: parse_date(params[:from]), to: parse_date(params[:to]), supplier_id: params[:supplier_id].presence, category_id: params[:category_id].presence,
      status: %w[pending partial paid voided].include?(params[:status]) ? params[:status] : nil,
      document_type: Obligation::DOCUMENT_TYPES.key?(params[:document_type]) ? params[:document_type] : nil
    }
  end

  def filtered_obligations
    scope = Obligation.expenses
    scope = scope.where("obligations.accrual_on >= ?", @filters[:from]) if @filters[:from]
    scope = scope.where("obligations.accrual_on <= ?", @filters[:to]) if @filters[:to]
    scope = scope.where(supplier_id: @filters[:supplier_id].to_i) if @filters[:supplier_id]
    scope = scope.where(document_type: @filters[:document_type]) if @filters[:document_type]
    scope = scope.where(source_id: Expense.where(expense_category_id: @filters[:category_id].to_i).select(:id)) if @filters[:category_id]
    case @filters[:status]
    when "pending" then scope.unpaid
    when "partial" then scope.partially_paid
    when "paid" then scope.settled
    when "voided" then scope.where.not(voided_at: nil)
    else scope
    end
  end
end
