class OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_customer!

  def new
    @cart_items = cart_items
    redirect_to cart_path, alert: "El carrito está vacío." if @cart_items.empty?
  end

  def index
    @orders = current_user.customer.orders
      .includes(:order_items)
      .order(created_at: :desc)
  end


  def repeat
    order = current_user.customer.orders
      .includes(:order_items)
      .find(params[:id])

    session[:cart] = {}

    order.order_items.each do |item|
      next unless item.product.present? && item.product.active?

      session[:cart][item.product.id.to_s] = item.quantity
    end

    redirect_to cart_path, notice: "Pedido cargado nuevamente en el carrito."
  end

  def create
    @cart_items = cart_items

    if @cart_items.empty?
      redirect_to cart_path, alert: "El carrito está vacío."
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
    products = Product.where(id: product_ids).includes(:category).index_by(&:id)

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

  def require_customer!
    redirect_to admin_root_path if current_user.admin?
  end
end