# Alta/edición de la configuración de stock de un Product o una
# Preparation (control_stock + mínimo) — solo admin, ver punto 18 del
# pedido original ("modificar mínimos, cambiar configuración de stock").
# Las acciones operativas del día a día (producción/conteo) están abajo,
# con permisos más amplios (admin_or_production).
class Admin::StockItemsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin_or_production!, only: [:show, :register_production, :register_count]
  before_action :require_admin!, only: [:create, :update]
  before_action :set_stock_item, only: [:show, :update, :register_production, :register_count]

  def show
    @snapshot = Stock::Availability.for_item(@stock_item)
    @movements = @stock_item.stock_movements.order(created_at: :desc, id: :desc).includes(:order, :user).limit(200)
  end

  def create
    stockable = resolve_stockable(params.dig(:stock_item, :stockable_type), params.dig(:stock_item, :stockable_id))

    if stockable.nil?
      redirect_to admin_root_path, alert: "No se encontró el producto/preparación."
      return
    end

    stock_item = stockable.build_stock_item(stock_item_params)

    if stock_item.save
      redirect_to stockable_edit_path(stockable), notice: "Configuración de stock guardada."
    else
      redirect_to stockable_edit_path(stockable), alert: stock_item.errors.full_messages.join(", ")
    end
  end

  def update
    if @stock_item.update(stock_item_params)
      redirect_to stockable_edit_path(@stock_item.stockable), notice: "Configuración de stock actualizada."
    else
      redirect_to stockable_edit_path(@stock_item.stockable), alert: @stock_item.errors.full_messages.join(", ")
    end
  end

  def register_production
    Stock::RegisterProduction.call(stock_item: @stock_item, quantity: params[:quantity], user: current_user, note: params[:note].presence)
    redirect_to admin_stock_path, notice: "Producción registrada: +#{helpers.format_quantity(params[:quantity])} #{@stock_item.unit} de #{@stock_item.name}."
  rescue Stock::RegisterProduction::InvalidQuantityError => e
    redirect_to admin_stock_path, alert: e.message
  end

  def register_count
    Stock::RegisterAdjustment.call(stock_item: @stock_item, counted_quantity: params[:counted_quantity], user: current_user, note: params[:note].presence)
    redirect_to admin_stock_path, notice: "Conteo registrado para #{@stock_item.name}: stock real = #{helpers.format_quantity(params[:counted_quantity])} #{@stock_item.unit}."
  rescue Stock::RegisterAdjustment::InvalidQuantityError => e
    redirect_to admin_stock_path, alert: e.message
  end

  private

  def set_stock_item
    @stock_item = StockItem.find(params[:id])
  end

  def resolve_stockable(type, id)
    return nil unless %w[Product Preparation].include?(type)

    type.constantize.find_by(id: id)
  end

  def stockable_edit_path(stockable)
    stockable.is_a?(Product) ? edit_admin_product_path(stockable) : edit_admin_preparation_path(stockable)
  end

  def stock_item_params
    params.require(:stock_item).permit(:minimum_quantity, :active)
  end
end
