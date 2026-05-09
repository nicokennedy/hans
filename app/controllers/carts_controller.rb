class CartsController < ApplicationController
  before_action :authenticate_user!
  before_action :require_customer!

  def show
    @cart_items = cart_items
  end

  def add
    @product = Product.active.find(params[:product_id])
    current_cart[@product.id.to_s] = current_cart[@product.id.to_s].to_i + 1

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to dashboard_path }
    end
  end

  def update_item
    @product = Product.find(params[:product_id])
    quantity = params[:quantity].to_i

    if quantity <= 0
      current_cart.delete(@product.id.to_s)
    else
      current_cart[@product.id.to_s] = quantity
    end

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to dashboard_path }
    end
  end

  def remove_item
    current_cart.delete(params[:product_id].to_s)
    redirect_to cart_path, notice: "Producto eliminado."
  end

  def clear
    session[:cart] = {}
    redirect_to cart_path, notice: "Carrito vaciado."
  end

  private

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