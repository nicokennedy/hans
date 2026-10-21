# Panel diario de Stock/Producción. Solo lectura salvo por las acciones
# rápidas (registrar producción / contar stock), que viven en
# Admin::StockItemsController. Accesible para admin y production, igual
# que Pedidos/Producción — es la pantalla operativa de cocina.
class Admin::StockController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_or_production!

  def show
    @snapshots = Stock::Availability.dashboard
  end

  # Planilla .xlsx para el control físico (ver Stock::ExcelExporter). Usa las mismas fotos que
  # el panel (incluida su conciliación automática de salidas vencidas, que es idempotente y
  # ya corrió al abrir el panel); exportar no registra producciones, conteos ni ajustes.
  def export
    now = Time.current
    send_data Stock::ExcelExporter.new(Stock::Availability.dashboard(now: now), generated_at: now).call,
      filename: Stock::ExcelExporter.filename(now),
      type: Stock::ExcelExporter::CONTENT_TYPE,
      disposition: "attachment"
  end
end
