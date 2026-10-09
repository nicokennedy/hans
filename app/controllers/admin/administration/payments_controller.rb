# Pagos a proveedores: independientes de la carga de compras y gastos, con imputación
# automática (más vencida primero) que se puede editar antes de confirmar.
class Admin::Administration::PaymentsController < Admin::Administration::BaseController
  include FinanceParams

  def index
    scope = OutgoingPayment.includes(:supplier, :user).order(paid_on: :desc, id: :desc)
    scope = scope.where(supplier_id: params[:supplier_id].to_i) if params[:supplier_id].present?
    scope = scope.where("paid_on >= ?", parse_date(params[:from])) if parse_date(params[:from])
    scope = scope.where("paid_on <= ?", parse_date(params[:to])) if parse_date(params[:to])
    scope = scope.where(voided_at: nil) if params[:status] == "active"
    scope = scope.where.not(voided_at: nil) if params[:status] == "voided"
    @payments = paginate(scope)
    @suppliers = Supplier.ordered
  end

  def show
    @payment = OutgoingPayment.includes(applications: :obligation).find(params[:id])
  end

  def new
    prepare_form
    @form = { paid_on: Date.current.iso8601, payment_method: "bank_transfer", amount: "", reference: "", note: "", allocations: {} }

    if params[:obligation_id].present? && (obligation = @pending.find { |o| o.id == params[:obligation_id].to_i })
      @form[:amount] = Finance::Money.format_pesos(obligation.balance_cents)
      @form[:allocations] = { obligation.id.to_s => Finance::Money.format_pesos(obligation.balance_cents) }
    end
  end

  def create
    prepare_form(token: params[:request_token])
    amount, e1 = money_param(params[:amount], "El importe")
    paid_on, e2 = date_param(params[:paid_on], "La fecha del pago", required: true)
    raw = params[:allocations].respond_to?(:to_unsafe_h) ? params[:allocations].to_unsafe_h : {}
    allocations, parse_errors = parse_allocations(raw)
    upload = upload_param
    errors = [e1, e2].compact + parse_errors + attachment_errors(upload)
    errors << "Indicá el importe pagado." if amount.nil? && e1.nil?

    result = if errors.empty?
      Finance::RegisterPayment.call(supplier: @supplier, user: current_user, amount_cents: amount, paid_on: paid_on, payment_method: params[:payment_method], allocations: allocations,
                                    reference: params[:reference], note: params[:note], request_token: params[:request_token], upload: upload)
    else
      Finance::Result.new(errors: errors)
    end

    if result.ok?
      redirect_to admin_administration_payment_path(result.payment), notice: success_message(result)
    else
      @errors = result.errors
      @form = { paid_on: params[:paid_on], payment_method: params[:payment_method], amount: params[:amount].to_s, reference: params[:reference].to_s, note: params[:note].to_s, allocations: raw }
      render :new, status: :unprocessable_entity
    end
  end

  def void
    payment = OutgoingPayment.find(params[:id])
    result = Finance::VoidPayment.call(payment: payment, user: current_user, reason: params[:reason])
    redirect_to admin_administration_payment_path(payment), result.ok? ? { notice: "Pago anulado. Los saldos de las obligaciones se restablecieron y el registro se conserva." } : { alert: result.errors.join(" ") }
  end

  private

  # supplier_id=none -> gastos sin proveedor.
  def prepare_form(token: nil)
    @suppliers = Supplier.ordered
    @no_supplier = params[:supplier_id] == "none"
    @supplier = Supplier.find_by(id: params[:supplier_id]) unless @no_supplier
    @pending = if @supplier
      Finance::Distribution.pending_obligations(@supplier).includes(:source).to_a
    elsif @no_supplier
      Obligation.where(supplier_id: nil).outstanding.with_paid.oldest_first.includes(:source).to_a
    else
      []
    end
    @request_token = token.presence || SecureRandom.uuid
    @advance_cents = @supplier ? Finance::ApplyAdvance.available_cents(@supplier) : 0
  end

  def parse_allocations(raw)
    allocations = {}
    errors = []

    raw.each_pair do |obligation_id, text|
      next if text.to_s.strip.empty?

      cents = Finance::Money.parse_pesos(text)
      id = Integer(obligation_id.to_s, exception: false)
      cents.nil? || id.nil? ? errors << "El importe «#{text.to_s.truncate(20)}» no es válido." : allocations[id] = cents
    end

    [allocations, errors]
  end

  def success_message(result)
    base = result.duplicate? ? "Este pago ya estaba registrado (se evitó duplicarlo)." : "Pago registrado."
    return base unless result.advance_cents.to_i.positive?

    "#{base} Quedaron $#{Finance::Money.format_pesos(result.advance_cents)} como anticipo del proveedor."
  end
end
