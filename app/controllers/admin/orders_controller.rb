class Admin::OrdersController < ApplicationController
  include OrdersNavigationContext

  before_action :authenticate_user!
  before_action :require_admin_or_production!, only: [:index, :show, :receipts]
  before_action :require_admin!, only: [:new, :create, :edit, :update, :export]

  PAYMENT_STATUS_FILTERS = Orders::ListFilters::PAYMENT_STATUSES

  # Una copia queda en el comercio y la otra vuelve firmada con el repartidor.
  DELIVERY_NOTE_COPIES = 2

  def index
    # El filtro de estado de pago sigue guardándose en la sesión (como antes: persiste
    # entre pantallas y lo usa el export); cliente, fecha y página viajan en la URL.
    if params[:payment_status_filter].present? && current_user.admin?
      session[:orders_payment_status_filter] = params[:payment_status_filter]
    end

    @filters = list_filters
    @payment_status_filter = @filters.payment_status
    @orders = @filters.paginate(filtered_orders(includes: :customer))
    @customers = Customer.order(:name).pluck(:name, :id)
  end

  # El costo (unit_cost_cents_snapshot) que trae el CSV es información
  # interna, así que esta acción exige :require_admin! arriba — a
  # diferencia de index/show, production no puede acceder ni al botón ni
  # entrando directo a la URL.
  def export
    @filters = list_filters
    @payment_status_filter = @filters.payment_status
    orders = filtered_orders(includes: [ :customer, :order_items ])

    csv = Orders::CsvExporter.new(orders).call

    send_data csv,
      filename: "pedidos-#{Date.current.iso8601}.csv",
      type: "text/csv; charset=utf-8",
      disposition: "attachment"
  end

  def show
    @order = Order.includes(:customer, :payments, order_items: :product).find(params[:id])
  end

  # Impresión masiva de remitos de una fecha de entrega. El servidor solo
  # elige los pedidos y renderiza cada remito con el mismo partial que el
  # remito individual; el armado de las hojas A4 y el PDF se hacen en el
  # navegador (bulk_receipts_controller.js), que es quien conoce la altura
  # real de cada remito.
  def receipts
    @copies = DELIVERY_NOTE_COPIES
    @date = receipts_date
    @orders = @date ? receipts_orders(@date) : Order.none
  end

  def new
    @order = Order.new
    @order.order_items.build
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category, :product_customer_accesses)
  end

  def create
    @order = build_order_from_params

    @order.errors.add(:base, "El pedido debe tener al menos un producto.") if @order.order_items.empty?

    if @order.errors.any?
      @customers = Customer.active.order(:name)
      @products = Product.active.ordered.includes(:category, :product_customer_accesses)
      render :new, status: :unprocessable_entity
      return
    end

    ActiveRecord::Base.transaction { @order.save! }

    redirect_to admin_order_path(@order), notice: "Pedido creado correctamente."
  rescue ActiveRecord::RecordInvalid
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category, :product_customer_accesses)
    render :new, status: :unprocessable_entity
  end

  def edit
    @order = Order.includes(:customer, order_items: :product).find(params[:id])
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category, :product_customer_accesses)
  end

  def update
    @order = Order.includes(order_items: :product).find(params[:id])
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category, :product_customer_accesses)

    ActiveRecord::Base.transaction do
      update_order_items
      add_new_order_items
      grant_exception_for_customer_change
      @order.update!(order_params)
    end

    redirect_to admin_order_path(@order, orders_context), notice: "Pedido actualizado correctamente."
  rescue ActiveRecord::RecordInvalid => e
    @order = Order.includes(order_items: :product).find(params[:id])
    e.record.errors.full_messages.each { |message| @order.errors.add(:base, message) }
    @customers = Customer.active.order(:name)
    @products = Product.active.ordered.includes(:category, :product_customer_accesses)
    render :edit, status: :unprocessable_entity
  end

  private

  # Filtros efectivos del listado: lo que trae la URL y, para el estado de pago,
  # lo último guardado en la sesión si la URL no trae uno (comportamiento previo).
  # index y export usan exactamente esta misma resolución.
  def list_filters
    stored = session[:orders_payment_status_filter]
    Orders::ListFilters.new(params, payment_fallback: stored, allow_payment: current_user.admin?)
  end

  def receipts_date
    return Date.current if params[:date].blank?

    Date.iso8601(params[:date])
  rescue ArgumentError
    flash.now[:alert] = "La fecha no es válida."
    nil
  end

  # Orden estable y legible para quien imprime: por cliente y, a igual
  # cliente, por antigüedad del pedido.
  def receipts_orders(date)
    Order.for_delivery_date(date)
      .joins(:customer)
      .preload(:customer, :order_items)
      .order("customers.name", "orders.id")
  end

  def filtered_orders(includes:)
    @filters.apply(Order.includes(includes).order(created_at: :desc, id: :desc))
  end

  def order_params
    params.require(:order).permit(
      :customer_id,
      :delivery_date,
      :status,
      :payment_method_selected,
      :customer_comment
    )
  end

  def new_order_params
    params.require(:order).permit(
      :customer_id,
      :delivery_date,
      :status,
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
      grant_restriction_exception(item)
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
        duplicate.quantity = duplicate.quantity + item_params[:quantity].to_i
        grant_restriction_exception(duplicate)
        duplicate.save!
        item.destroy!
      else
        item.assign_product(new_product)
        apply_order_item_changes(item, item_params)
      end
    end
  end

  # Al reasignar el pedido a otro cliente con la excepción marcada, deja registrados los ítems
  # que ese cliente no tiene habilitados (sin la casilla, Order rechaza el cambio).
  def grant_exception_for_customer_change
    return unless restriction_exception_requested?

    new_customer = Customer.find_by(id: order_params[:customer_id])
    return if new_customer.nil? || new_customer.id == @order.customer_id

    @order.order_items.reload.includes(:product).each do |item|
      next if item.restriction_override_by_id.present? || item.product.available_to?(new_customer)

      item.update!(restriction_override_by: current_user, restriction_override_at: Time.current)
    end
  end

  def apply_order_item_changes(item, item_params)
    item.quantity = item_params[:quantity]
    item.unit_price_amount = item_params[:unit_price_amount] if item_params[:unit_price_amount].present?
    grant_restriction_exception(item)
    item.save!
  end

  # Excepción administrativa EXPLÍCITA para cargar un producto no habilitado para el cliente
  # (casilla del formulario): solo se registra en los ítems que realmente la necesitan, con
  # quién y cuándo. Sin la casilla, el modelo rechaza el producto (ver OrderItem).
  def restriction_exception_requested?
    params[:allow_restricted_exception] == "1"
  end

  def grant_restriction_exception(item)
    return unless restriction_exception_requested? && item.adds_unauthorized_product?

    item.restriction_override_by = current_user
    item.restriction_override_at = Time.current
  end

  # Agrega una o más líneas nuevas a un pedido existente (vía "Agregar otra
  # línea" en /edit). Si un producto ya está en el pedido — en una línea
  # existente o en una línea nueva agregada antes en esta misma request —
  # se suma la cantidad ahí en vez de crear una línea duplicada, igual que
  # ya hacía update_order_items al reasignar el producto de una línea.
  def add_new_order_items
    Array(params[:new_order_items]).each do |item_params|
      next if item_params[:product_id].blank?

      quantity = item_params[:quantity].to_i
      next if quantity <= 0

      product = Product.find(item_params[:product_id])
      existing_item = @order.order_items.find_by(product_id: product.id)

      if existing_item
        existing_item.quantity = existing_item.quantity + quantity
        grant_restriction_exception(existing_item)
        existing_item.save!
      else
        attributes = { product: product, quantity: quantity }
        attributes[:unit_price_amount] = item_params[:unit_price_amount] if item_params[:unit_price_amount].present?
        new_item = @order.order_items.build(attributes)
        grant_restriction_exception(new_item)
        new_item.save!
      end
    end
  end

end