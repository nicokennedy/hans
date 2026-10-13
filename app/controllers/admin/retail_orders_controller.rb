# Pedidos minoristas (solo admin): alta/edición manual, listado con filtros, detalle y cambio de
# estado. Toda la lógica y validación vive en Retail::* (el controller solo lee params).
class Admin::RetailOrdersController < ApplicationController
  include FinanceParams
  include RetailNavigationContext

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_order, only: [:show, :edit, :update, :edit_status, :update_status]

  def index
    @filters = Retail::ListFilters.new(params)
    scope = Retail::ListFilters.order_by_nearest(@filters.apply(RetailOrder.all))
    @orders = @filters.paginate(scope).to_a
    flash.now[:alert] = "Alguna fecha del filtro no es válida y se ignoró." if @filters.invalid_date
  end

  def show
    @payments = @order.retail_order_payments.includes(:user, :voided_by).to_a
    @status_changes = @order.retail_order_status_changes.includes(:user).to_a
    @items = @order.retail_order_items.includes(:product).to_a
  end

  def new
    @order = RetailOrder.new(delivery_date: Date.current)
    @form = form_defaults(@order)
    prepare_form
  end

  def create
    @order = RetailOrder.new
    result = Retail::SaveOrder.call(order: @order, attributes: order_attributes, items: item_rows, user: current_user)

    if result.ok?
      redirect_to admin_retail_order_path(result.record, retail_context), notice: "Pedido minorista #{result.record.number} creado."
    else
      render_form_errors(:new, result.errors)
    end
  end

  def edit
    @form = form_defaults(@order)
    prepare_form
  end

  def update
    result = Retail::SaveOrder.call(order: @order, attributes: order_attributes, items: item_rows, user: current_user)

    if result.ok?
      redirect_to admin_retail_order_path(@order, retail_context), notice: "Pedido minorista #{@order.number} actualizado."
    else
      render_form_errors(:edit, result.errors)
    end
  end

  def edit_status
  end

  def update_status
    result = Retail::ChangeStatus.call(order: @order, to_status: params[:to_status], user: current_user, note: params[:note])

    if result.ok?
      redirect_to admin_retail_order_path(@order, retail_context), notice: "Estado actualizado: #{result.record.status_label}."
    else
      @errors = result.errors
      render :edit_status, status: :unprocessable_entity
    end
  end

  private

  def set_order
    @order = RetailOrder.find(params[:id])
  end

  def order_attributes
    params.permit(:buyer_name, :buyer_phone, :delivery_date, :delivery_kind, :delivery_time_note, :address, :notes, :planned_payment_method, :shipping).to_h
  end

  def item_rows
    hash_values(params[:items])
  end

  def form_defaults(order)
    items = order.persisted? ? order.retail_order_items.includes(:product).map { |item| item_form_row(item) } : []
    {
      buyer_name: order.buyer_name, buyer_phone: order.buyer_phone, delivery_date: order.delivery_date,
      delivery_kind: order.delivery_kind, delivery_time_note: order.delivery_time_note, address: order.address,
      notes: order.notes, planned_payment_method: order.planned_payment_method,
      shipping: order.shipping_cents.positive? ? Retail::Money.format_pesos(order.shipping_cents) : "",
      items: items
    }
  end

  def item_form_row(item)
    {
      "id" => item.id, "kind" => (item.catalog? ? "product" : "manual"), "product_id" => item.product_id,
      "description" => item.description, "quantity" => item.quantity, "unit_price" => Retail::Money.format_pesos(item.unit_price_cents)
    }
  end

  def render_form_errors(action, errors)
    @errors = errors
    @form = {
      buyer_name: params[:buyer_name], buyer_phone: params[:buyer_phone], delivery_date: params[:delivery_date],
      delivery_kind: params[:delivery_kind], delivery_time_note: params[:delivery_time_note], address: params[:address],
      notes: params[:notes], planned_payment_method: params[:planned_payment_method], shipping: params[:shipping],
      items: item_rows
    }
    prepare_form
    render action, status: :unprocessable_entity
  end

  def prepare_form
    @products = Product.active.ordered.to_a
  end
end
