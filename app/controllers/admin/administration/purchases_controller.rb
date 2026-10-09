# Compras de mercadería. En esta etapa NO tocan stock, materias primas, recetas ni costos.
class Admin::Administration::PurchasesController < Admin::Administration::BaseController
  include FinanceParams

  before_action :set_obligation, only: [:show, :edit, :update, :destroy, :void]

  def index
    @filters = list_filters
    scope = filtered_obligations
    respond_to do |format|
      format.html do
        @obligations = paginate(scope.order(accrual_on: :desc, id: :desc)).with_paid.includes(:supplier, source: :items)
        @totals = { amount: scope.sum(:amount_cents), balance: scope.active.sum("obligations.amount_cents - #{Obligation::PAID_SQL}") }
      end
      format.csv do
        send_data Finance::CsvExport.purchases(scope.with_paid.includes(:supplier).order(accrual_on: :desc, id: :desc)), filename: "compras-#{Date.current.iso8601}.csv", type: "text/csv; charset=utf-8", disposition: "attachment"
      end
    end
  end

  def export
    redirect_to admin_administration_purchases_path(request.query_parameters.symbolize_keys.merge(format: :csv))
  end

  def show
    @purchase = @obligation.source
    @applications = @obligation.applications.includes(:outgoing_payment).order(:created_at)
  end

  def new
    @form = { accrual_on: Date.current.iso8601, items: [{}] }
    prepare_form
  end

  def create
    save_and_respond(nil)
  end

  def edit
    @purchase = @obligation.source
    @form = form_from_record
    prepare_form
  end

  def update
    save_and_respond(@obligation.source)
  end

  def destroy
    result = Finance::DestroySource.call(@obligation.source)
    if result.ok?
      redirect_to admin_administration_purchases_path, notice: "Compra eliminada."
    else
      redirect_to admin_administration_purchase_path(@obligation), alert: result.errors.join(" ")
    end
  end

  def void
    result = Finance::VoidObligation.call(obligation: @obligation, user: current_user, reason: params[:reason])
    redirect_to admin_administration_purchase_path(@obligation), result.ok? ? { notice: "Compra anulada. El registro se conserva." } : { alert: result.errors.join(" ") }
  end

  private

  def set_obligation
    @obligation = Obligation.purchases.find(params[:id])
  end

  def prepare_form
    @suppliers = Supplier.active.ordered
    @suppliers = Supplier.where(id: [*@suppliers.map(&:id), @purchase&.obligation&.supplier_id].compact).ordered
    @request_token = params[:request_token].presence || SecureRandom.uuid
  end

  def form_from_record
    obligation = @purchase.obligation
    {
      supplier_id: obligation.supplier_id, accrual_on: obligation.accrual_on.iso8601, due_on: obligation.due_on&.iso8601, document_type: obligation.document_type,
      document_number: obligation.document_number, notes: obligation.notes, discount: Finance::Money.format_pesos(@purchase.discount_cents), taxes: Finance::Money.format_pesos(@purchase.taxes_cents),
      adjustments: Finance::Money.format_pesos(@purchase.adjustments_cents),
      items: @purchase.items.map { |i| { "id" => i.id, "description" => i.description, "quantity" => Finance::Money.format_quantity(i.quantity), "unit" => i.unit, "unit_price" => Finance::Money.format_pesos(i.unit_price_cents) } }
    }
  end

  def save_and_respond(purchase)
    accrual_on, e1 = date_param(params[:accrual_on], "La fecha de compra", required: true)
    due_on, e2 = date_param(params[:due_on], "La fecha de vencimiento")
    discount, e3 = money_param(params[:discount], "El descuento", blank: 0)
    taxes, e4 = money_param(params[:taxes], "Los impuestos", blank: 0)
    adjustments, e5 = money_param(params[:adjustments], "Otros ajustes", blank: 0, signed: true)
    items, item_errors, raw_items = parse_purchase_items(params[:items])
    pay_now, pay_errors = purchase ? [nil, []] : parse_pay_now
    upload = upload_param
    errors = [e1, e2, e3, e4, e5].compact + item_errors + pay_errors + attachment_errors(upload)

    result = if errors.empty?
      Finance::SavePurchase.call(
        user: current_user, purchase: purchase, upload: upload, pay_now: pay_now, items: items,
        attributes: { supplier_id: params[:supplier_id], accrual_on: accrual_on, due_on: due_on, document_type: params[:document_type].presence, document_number: params[:document_number].to_s.strip.presence, notes: params[:notes].to_s.strip.presence },
        totals: { discount_cents: discount, taxes_cents: taxes, adjustments_cents: adjustments }
      )
    else
      Finance::Result.new(errors: errors)
    end

    if result.ok?
      redirect_to admin_administration_purchase_path(result.record.obligation), notice: purchase ? "Compra actualizada." : "Compra registrada."
    else
      @errors = result.errors
      @purchase = purchase
      @obligation = purchase&.obligation
      @form = params.permit(:supplier_id, :accrual_on, :due_on, :document_type, :document_number, :notes, :discount, :taxes, :adjustments, :pay_now, :pay_amount, :pay_method, :pay_reference, :pay_paid_on).to_h.symbolize_keys.merge(items: raw_items.presence || [{}])
      prepare_form
      render(purchase ? :edit : :new, status: :unprocessable_entity)
    end
  end

  def list_filters
    {
      from: parse_date(params[:from]), to: parse_date(params[:to]), supplier_id: params[:supplier_id].presence,
      status: %w[pending partial paid voided].include?(params[:status]) ? params[:status] : nil,
      document_type: Obligation::DOCUMENT_TYPES.key?(params[:document_type]) ? params[:document_type] : nil
    }
  end

  def filtered_obligations
    scope = Obligation.purchases
    scope = scope.where("obligations.accrual_on >= ?", @filters[:from]) if @filters[:from]
    scope = scope.where("obligations.accrual_on <= ?", @filters[:to]) if @filters[:to]
    scope = scope.where(supplier_id: @filters[:supplier_id].to_i) if @filters[:supplier_id]
    scope = scope.where(document_type: @filters[:document_type]) if @filters[:document_type]
    case @filters[:status]
    when "pending" then scope.unpaid
    when "partial" then scope.partially_paid
    when "paid" then scope.settled
    when "voided" then scope.where.not(voided_at: nil)
    else scope
    end
  end
end
