# Cuentas corrientes de proveedores: listado de saldos y detalle cronológico por proveedor
# (con filtro de fechas y CSV).
class Admin::Administration::SupplierAccountsController < Admin::Administration::BaseController
  def index
    @query = params[:q].to_s.strip
    balances = Finance::Summary.new.supplier_balances
    @rows = @query.present? ? balances.select { |row| row[:supplier].name.downcase.include?(@query.downcase) } : balances
    @total_pending = balances.sum { |row| row[:pending_cents] }
    @total_advances = balances.sum { |row| row[:advance_cents] }
  end

  def show
    @supplier = Supplier.find(params[:supplier_id])
    @account = Finance::SupplierAccount.new(@supplier, from: params[:from], to: params[:to])

    respond_to do |format|
      format.html do
        @advance_cents = Finance::ApplyAdvance.available_cents(@supplier)
      end
      format.csv do
        send_data Finance::CsvExport.supplier_account(@account), filename: "cuenta-corriente-#{@supplier.name.parameterize}-#{Date.current.iso8601}.csv", type: "text/csv; charset=utf-8", disposition: "attachment"
      end
    end
  end
end
