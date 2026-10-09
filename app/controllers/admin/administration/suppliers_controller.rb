class Admin::Administration::SuppliersController < Admin::Administration::BaseController
  before_action :set_supplier, only: [:show, :edit, :update, :destroy, :toggle_active]

  def index
    @status = %w[active inactive].include?(params[:status]) ? params[:status] : "all"
    @query = params[:q].to_s.strip
    scope = Supplier.search(@query).ordered
    scope = scope.where(active: true) if @status == "active"
    scope = scope.where(active: false) if @status == "inactive"
    @suppliers = paginate(scope)
    @balances = Finance::Summary.new.supplier_balances.index_by { |row| row[:supplier].id }
  end

  def show
    @account = Finance::SupplierAccount.new(@supplier)
    @obligations = @supplier.obligations.includes(:source).with_paid.order(accrual_on: :desc, id: :desc).limit(100)
    @payments = @supplier.outgoing_payments.order(paid_on: :desc, id: :desc).limit(100)
  end

  def new
    @supplier = Supplier.new(active: true)
  end

  def create
    @supplier = Supplier.new(supplier_params)

    if @supplier.save
      redirect_to admin_administration_supplier_path(@supplier), notice: "Proveedor creado."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @supplier.update(supplier_params)
      redirect_to admin_administration_supplier_path(@supplier), notice: "Proveedor actualizado."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # Un proveedor con movimientos no se borra: se desactiva (el historial se conserva).
  def destroy
    if @supplier.deletable? && @supplier.destroy
      redirect_to admin_administration_suppliers_path, notice: "Proveedor eliminado."
    else
      redirect_to admin_administration_supplier_path(@supplier), alert: "Este proveedor tiene movimientos: no se puede eliminar, solo desactivar."
    end
  end

  def toggle_active
    @supplier.update!(active: !@supplier.active?)
    redirect_to admin_administration_supplier_path(@supplier), notice: @supplier.active? ? "Proveedor reactivado." : "Proveedor desactivado. Su historial se conserva."
  end

  private

  def set_supplier
    @supplier = Supplier.find(params[:id])
  end

  def supplier_params
    params.require(:supplier).permit(:name, :tax_id, :email, :phone, :address, :notes, :active)
  end
end
