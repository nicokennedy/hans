# Aplicación explícita de anticipos de un proveedor a sus obligaciones pendientes.
class Admin::Administration::AdvanceApplicationsController < Admin::Administration::BaseController
  before_action :set_supplier

  def new
    prepare_form
    @allocations = {}
  end

  def create
    prepare_form
    raw = params[:allocations].respond_to?(:to_unsafe_h) ? params[:allocations].to_unsafe_h : {}
    allocations = {}
    errors = []

    raw.each_pair do |obligation_id, text|
      next if text.to_s.strip.empty?

      cents = Finance::Money.parse_pesos(text)
      cents.nil? ? errors << "El importe «#{text.to_s.truncate(20)}» no es válido." : allocations[obligation_id] = cents
    end

    result = errors.any? ? Finance::Result.new(errors: errors) : Finance::ApplyAdvance.call(supplier: @supplier, user: current_user, allocations: allocations)

    if result.ok?
      redirect_to admin_administration_supplier_account_path(@supplier), notice: "Anticipo aplicado. Te quedan $#{Finance::Money.format_pesos(result.advance_cents)} de anticipo."
    else
      @errors = result.errors
      @allocations = raw
      render :new, status: :unprocessable_entity
    end
  end

  def revert
    application = OutgoingPaymentApplication.joins(:outgoing_payment).where(outgoing_payments: { supplier_id: @supplier.id }).find(params[:id])
    result = Finance::RevertAdvanceApplication.call(application: application, user: current_user, reason: params[:reason])
    redirect_to admin_administration_supplier_account_path(@supplier), result.ok? ? { notice: "Aplicación revertida: el importe volvió a ser anticipo y la obligación recuperó su saldo." } : { alert: result.errors.join(" ") }
  end

  private

  def set_supplier
    @supplier = Supplier.find(params[:supplier_id])
  end

  def prepare_form
    @pending = Finance::Distribution.pending_obligations(@supplier).includes(:source).to_a
    @advance_cents = Finance::ApplyAdvance.available_cents(@supplier)
  end
end
