module DeliveryIncomeForms
  extend ActiveSupport::Concern

  included do
    before_action :load_income_route
    before_action :load_income, only: [:edit, :update]
  end

  def index
    @incomes = DeliveryRoutes::Settlement.new(@route).incomes
    render "reparto/incomes/index"
  end

  def new
    render_form
  end

  def edit
    render_form
  end

  def create
    save_income
  end

  def update
    save_income
  end

  private

  def load_income
    @income = @route.incomes.find(params[:id])
  end

  def render_form
    if (denied = DeliveryRoutes::Access.money_error(@route, current_user))
      redirect_to income_index_path, alert: denied
    else
      @request_token = SecureRandom.uuid
      render "reparto/incomes/form"
    end
  end

  def save_income
    result = DeliveryRoutes::Incomes.new(@route, current_user).save(
      kind: params[:kind], description: params[:description],
      amount_cents: CustomerAccounts::Money.parse_pesos(params[:importe]),
      token: params[:request_token], old: @income, reason: params[:motivo].to_s.squish.presence
    )
    if result.error
      @request_token = params[:request_token].presence || SecureRandom.uuid
      flash.now[:alert] = result.error
      render "reparto/incomes/form", status: :unprocessable_entity
      return
    end

    file = params[:evidence].presence || params[:evidence_gallery].presence || params[:evidence_camera]
    if result.income && !DeliveryRoutes::OptionalEvidence.attach(result.income, file, current_user)
      redirect_to income_index_path, alert: "Se guardó el ingreso sin el comprobante. No se pudo cargar."
    else
      redirect_to income_index_path, notice: "Listo, quedó guardado."
    end
  end
end
