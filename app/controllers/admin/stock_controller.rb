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
end
