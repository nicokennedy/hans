class OrdersController < ApplicationController
  include CartAvailability

  before_action :authenticate_user!
  before_action :require_customer!

  def new
    @cart_items = cart_items
    return redirect_to cart_path, alert: "El carrito está vacío." if @cart_items.empty?

    unavailable = unavailable_cart_product_names(@cart_items)
    redirect_to cart_path, alert: unavailable_cart_message(unavailable) if unavailable.any?
  end

  def index
    @orders = current_user.customer.orders
      .includes(:order_items)
      .order(created_at: :desc)

    billable_orders = current_user.customer.orders.not_canceled
    @total_invoiced_cents = billable_orders.sum(:total_cents)
    @total_paid_cents = billable_orders.sum(:amount_paid_cents)
    @balance_due_cents = @total_invoiced_cents - @total_paid_cents
  end


  def repeat
    order = current_user.customer.orders
      .includes(:order_items)
      .find(params[:id])

    session[:cart] = {}

    # Solo productos activos y habilitados para este cliente (visibilidad por cliente).
    orderable_ids = Product.active.available_to(current_user.customer).where(id: order.order_items.map(&:product_id)).pluck(:id).to_set

    order.order_items.each do |item|
      next unless orderable_ids.include?(item.product_id)

      session[:cart][item.product_id.to_s] = item.quantity
    end

    redirect_to cart_path, notice: "Pedido cargado nuevamente en el carrito."
  end

  def create
    @cart_items = cart_items

    if @cart_items.empty?
      redirect_to cart_path, alert: "El carrito está vacío."
      return
    end

    # Nada se guarda si algún producto no está habilitado para el cliente (ni siquiera parcial).
    unavailable = unavailable_cart_product_names(@cart_items)
    if unavailable.any?
      redirect_to cart_path, alert: unavailable_cart_message(unavailable)
      return
    end

    order = current_user.customer.orders.build(order_params)

    @cart_items.each do |item|
      order.order_items.build(
        product: item[:product],
        quantity: item[:quantity]
      )
    end

    if order.save
      session[:cart] = {}
      redirect_to order_path(order), notice: "Pedido creado correctamente."
    else
      @order = order
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @order = current_user.customer.orders.includes(order_items: :product).find(params[:id])
  end

  private

  def order_params
    params.require(:order).permit(:delivery_date, :payment_method_selected, :customer_comment)
  end

  def current_cart
    session[:cart] ||= {}
  end

  def cart_items
    product_ids = current_cart.keys
    products = Product.where(id: product_ids).includes(:category, :product_customer_accesses).index_by(&:id)

    current_cart.map do |product_id, quantity|
      product = products[product_id.to_i]
      next if product.blank?

      {
        product: product,
        quantity: quantity.to_i,
        subtotal_cents: product.price_cents.to_i * quantity.to_i
      }
    end.compact
  end

end
