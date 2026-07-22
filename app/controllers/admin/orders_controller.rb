class Admin::OrdersController < ApplicationController
  before_action :authenticate_user!
  before_action :require_admin!

  def index
    @orders = Order.includes(:customer).order(created_at: :desc)
  end

  def show
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
  end

  def new
    @order = Order.new
    @order.order_items.build
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category)
  end

  def create
    @order = build_order_from_params

    @order.errors.add(:base, "El pedido debe tener al menos un producto.") if @order.order_items.empty?

    if @order.errors.any?
      @customers = Customer.active.order(:name)
      @products = Product.active.ordered.includes(:category)
      render :new, status: :unprocessable_entity
      return
    end

    ActiveRecord::Base.transaction { @order.save! }

    redirect_to admin_order_path(@order), notice: "Pedido creado correctamente."
  rescue ActiveRecord::RecordInvalid
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category)
    render :new, status: :unprocessable_entity
  end

  def edit
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
    @products = Product.active.ordered.includes(:category)
  end

  def update
    @order = Order.includes(order_items: :product).find(params[:id])
    @products = Product.active.ordered.includes(:category)

    ActiveRecord::Base.transaction do
      update_order_items
      add_new_order_item
      @order.update!(order_params)
    end

    redirect_to admin_order_path(@order), notice: "Pedido actualizado correctamente."
  rescue ActiveRecord::RecordInvalid => e
    @order = Order.includes(order_items: :product).find(params[:id])
    e.record.errors.full_messages.each { |message| @order.errors.add(:base, message) }
    @products = Product.active.ordered.includes(:category)
    render :edit, status: :unprocessable_entity
  end

  private

  def order_params
    params.require(:order).permit(
      :delivery_date,
      :status,
      :customer_comment
    )
  end

  def new_order_params
    params.require(:order).permit(
      :customer_id,
      :delivery_date,
      :status,
      :payment_status,
      :payment_method_selected,
      :customer_comment
    )
  end

  def build_order_from_params
    order = Order.new(new_order_params.merge(created_by_admin: true))

    Array(params[:order_items]).each do |item_params|
      next if item_params[:product_id].blank? && item_params[:unit_price_amount].blank?

      if item_params[:product_id].blank?
        order.errors.add(:base, "Hay una fila con precio cargado pero sin producto seleccionado.")
        next
      end

      product = Product.find_by(id: item_params[:product_id])

      if product.nil?
        order.errors.add(:base, "Uno de los productos seleccionados ya no existe.")
        next
      end

      item = order.order_items.build(product: product, quantity: item_params[:quantity])
      item.unit_price_amount = item_params[:unit_price_amount] if item_params[:unit_price_amount].present?
    end

    order
  end

  # Processed in three passes so a line being merged always adds its quantity
  # on top of the *final* quantity of the line it merges into, no matter what
  # order the form fields happen to arrive in:
  #   1) removals, so a removed line is never treated as a merge target
  #   2) plain quantity/price edits for lines that keep their product
  #   3) product reassignments, merging into a duplicate if one exists
  def update_order_items
    return unless params[:order_items].present?

    params[:order_items].each do |id, item_params|
      next unless item_params[:remove] == "1"

      @order.order_items.find(id).destroy!
    end

    reassigned_ids = []

    params[:order_items].each do |id, item_params|
      next if item_params[:remove] == "1"

      item = @order.order_items.find(id)

      if item_params[:product_id].present? && item_params[:product_id].to_i != item.product_id
        reassigned_ids << id
        next
      end

      apply_order_item_changes(item, item_params)
    end

    reassigned_ids.each do |id|
      item_params = params[:order_items][id]
      item = @order.order_items.find(id)
      new_product = Product.find(item_params[:product_id])
      duplicate = @order.order_items.where.not(id: item.id).find_by(product_id: new_product.id)

      if duplicate
        duplicate.update!(quantity: duplicate.quantity + item_params[:quantity].to_i)
        item.destroy!
      else
        item.assign_product(new_product)
        apply_order_item_changes(item, item_params)
      end
    end
  end

  def apply_order_item_changes(item, item_params)
    item.quantity = item_params[:quantity]
    item.unit_price_amount = item_params[:unit_price_amount] if item_params[:unit_price_amount].present?
    item.save!
  end

  def add_new_order_item
    return if params[:new_product_id].blank?
    return if params[:new_quantity].to_i <= 0

    product = Product.find(params[:new_product_id])
    existing_item = @order.order_items.find_by(product_id: product.id)

    if existing_item
      existing_item.update!(quantity: existing_item.quantity + params[:new_quantity].to_i)
    else
      attributes = { product: product, quantity: params[:new_quantity].to_i }
      attributes[:unit_price_amount] = params[:new_unit_price] if params[:new_unit_price].present?
      @order.order_items.create!(attributes)
    end
  end

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end
end