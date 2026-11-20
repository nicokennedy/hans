# R4: "¿Te pagaron?" en el celular del repartidor. Flujo guiado y con confirmación antes de
# guardar dinero: elegir respuesta → (importe) → (pedidos) → confirmar → guardado. El dinero lo
# registra DeliveryRoutes::Collections sobre la cuenta corriente existente. Solo efectivo: las
# transferencias las registra administración. Solo las paradas de los recorridos de HOY del
# repartidor (D5: solo ve los saldos de ese cliente).
class Reparto::CollectionsController < Reparto::BaseController
  KINDS = %w[todo parte otro identificar].freeze
  REPORTS = { "todo" => "paid_all", "parte" => "partial", "otro" => "other", "identificar" => "unidentified" }.freeze
  CORRECTION_REASONS = ["Me equivoqué de importe", "Al final no me pagaron", "Otro motivo"].freeze

  Plan = Struct.new(:kind, :amount_cents, :allocations, :unidentified, :errors, keyword_init: true) do
    def credit_cents
      unidentified ? amount_cents : amount_cents.to_i - allocations.values.sum
    end
  end

  before_action :require_driver!
  before_action :set_stop, except: [:edit, :confirm_correction, :correct]
  before_action :set_collection, only: [:edit, :confirm_correction, :correct]

  # ¿Te pagaron?
  def new
    load_balances
  end

  # ¿Cuánto te pagaron?
  def amount
    @kind = params[:tipo].to_s
    return redirect_to(reparto_stop_collection_path(@stop)) unless %w[parte otro identificar].include?(@kind)

    load_balances
  end

  # Pagó deudas anteriores u otro importe: ¿a qué pedidos corresponde?
  def orders
    @amount_cents = parse_pesos(params[:importe])
    return redirect_to(reparto_stop_collection_amount_path(@stop, tipo: "otro"), alert: "Escribí cuánto te pagaron.") unless @amount_cents&.positive?

    load_balances
    selected = Array(params[:pedidos]).map(&:to_i)
    selected = @orders.map(&:id) if selected.empty?
    @suggested = CustomerAccounts::Distribution.suggest(@orders.select { |o| selected.include?(o.id) }, @amount_cents).allocations
  end

  def confirm
    @plan = build_plan
    return redirect_to(back_path_for(@plan), alert: @plan.errors.join(" ")) if @plan.errors.any?

    @orders_by_id = Order.where(id: @plan.allocations.keys).index_by(&:id)
    @request_token = SecureRandom.uuid
  end

  def create
    # Reintento o doble toque de un cobro ya guardado: no se recalcula nada (el saldo ya cambió).
    if params[:request_token].present? && DeliveryCollection.exists?(request_token: params[:request_token].to_s, delivery_stop_id: @stop.id)
      return after_money_path(already: true)
    end

    plan = build_plan
    return redirect_to(back_path_for(plan), alert: plan.errors.join(" ")) if plan.errors.any?

    result = DeliveryRoutes::Collections.new(@stop.delivery_route, current_user).record(
      stop: @stop, amount_cents: plan.amount_cents, allocations: plan.allocations, unidentified: plan.unidentified,
      request_token: params[:request_token], report: REPORTS[plan.kind]
    )
    if result.ok?
      after_money_path(already: result.already)
    else
      redirect_to reparto_stop_collection_path(@stop), alert: result.errors.join(" ")
    end
  end

  # No me pagaron.
  def unpaid
    result = DeliveryRoutes::Collections.new(@stop.delivery_route, current_user).report_unpaid(@stop)
    return redirect_to(reparto_stop_collection_path(@stop), alert: result.errors.join(" ")) unless result.ok?

    after_money_path
  end

  # Corregir un cobro (antes de enviar la rendición), con motivo.
  def edit
  end

  def confirm_correction
    @amount_cents = parse_pesos(params[:importe])
    @reason = correction_reason
    errors = []
    errors << "Escribí el importe correcto (0 si no te pagaron)." if @amount_cents.nil?
    errors << "Elegí o escribí el motivo." if @reason.blank?
    errors << "Es el mismo importe: no hay nada que corregir." if @amount_cents == @collection.amount_cents
    return redirect_to(reparto_collection_correction_path(@collection), alert: errors.join(" ")) if errors.any?

    @request_token = SecureRandom.uuid
  end

  def correct
    amount = parse_pesos(params[:importe])
    result = DeliveryRoutes::Collections.new(@collection.delivery_route, current_user)
                                        .correct(@collection, amount_cents: amount, reason: correction_reason, request_token: params[:request_token])
    if result.ok?
      redirect_to reparto_stop_path(@collection.delivery_stop), notice: amount.to_i.zero? ? "Listo: el cobro quedó anulado." : "Listo: el cobro quedó corregido."
    else
      redirect_to reparto_collection_correction_path(@collection), alert: result.errors.join(" ")
    end
  end

  private

  def set_stop
    @stop = find_todays_stop(params[:stop_id])
    redirect_to reparto_stop_path(@stop), alert: "Esta parada no es un pedido." unless @stop.order?
  end

  def set_collection
    @collection = DeliveryCollection.where(delivery_route_id: todays_routes.map(&:id)).includes(:customer, delivery_stop: :order).find(params[:id])
    @stop = @collection.delivery_stop
    redirect_to reparto_stop_path(@stop), alert: "Ese cobro ya fue corregido." if @collection.voided?
  end

  def load_balances
    @orders = DeliveryRoutes::Collections.pending_orders_for(@stop)
    @own_balance = @stop.order.balance_due_cents
    @previous_orders = @orders.reject { |order| order.id == @stop.order_id }
    @previous_balance = @previous_orders.sum(&:balance_due_cents)
  end

  # Arma qué se va a registrar a partir de lo que eligió el repartidor. El servidor vuelve a
  # validar todo al guardar (saldos actuales, pedidos del cliente, importes).
  def build_plan
    kind = params[:tipo].to_s
    errors = []
    errors << "Elegí qué pasó con el pago." unless KINDS.include?(kind)
    own_balance = @stop.order.balance_due_cents
    amount = kind == "todo" ? own_balance : parse_pesos(params[:importe])
    allocations = {}
    unidentified = false

    case kind
    when "todo"
      errors << "Este pedido ya no tiene saldo para cobrar." unless own_balance.positive?
      allocations = { @stop.order_id => own_balance }
    when "parte"
      if amount.nil? || !amount.positive?
        errors << "Escribí cuánto te pagaron."
      elsif amount >= own_balance
        errors << "Es el total del pedido o más: elegí \"Me pagaron todo\" o \"Me pagaron otro importe\"."
      else
        allocations = { @stop.order_id => amount }
      end
    when "otro"
      if amount.nil? || !amount.positive?
        errors << "Escribí cuánto te pagaron."
      elsif params[:asignar].is_a?(ActionController::Parameters)
        allocations = params[:asignar].to_unsafe_h.each_with_object({}) do |(id, text), memo|
          cents = parse_pesos(text)
          memo[id.to_i] = cents if cents&.positive?
        end
        errors << "Lo repartido entre pedidos supera lo que te pagaron." if allocations.values.sum > amount
      else
        allocations = CustomerAccounts::Distribution.suggest([@stop.order].select { |o| o.balance_due_cents.positive? }, amount).allocations
      end
    when "identificar"
      errors << "Escribí cuánto te pagaron." unless amount&.positive?
      unidentified = true
    end

    Plan.new(kind: kind, amount_cents: amount, allocations: allocations, unidentified: unidentified, errors: errors)
  end

  def back_path_for(plan)
    %w[parte otro identificar].include?(plan.kind) ? reparto_stop_collection_amount_path(@stop, tipo: plan.kind) : reparto_stop_collection_path(@stop)
  end

  # Después del dinero: si el pedido entregado quedó con saldo, foto del remito (D9).
  def after_money_path(already: false)
    @stop.reload
    if @stop.receipt_photo_pending?
      redirect_to reparto_stop_photo_path(@stop)
    else
      redirect_to saved_reparto_stop_path(@stop, ya: (already ? 1 : nil))
    end
  end

  def correction_reason
    choice = params[:motivo].to_s
    choice == "Otro motivo" || !CORRECTION_REASONS.include?(choice) ? params[:motivo_texto].to_s.squish.presence : choice
  end
end
