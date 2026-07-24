class Admin::CustomersController < ApplicationController
  include CollectionsPeriodFilterable

  before_action :authenticate_user!
  before_action :require_admin!
  before_action :set_customer, only: [:show, :edit, :update, :toggle_active]
  before_action :set_user, only: [:edit, :update]

  def index
    @customers = Customer.includes(:users).order(:name)

    range = @collections_period.from..@collections_period.to
    @invoiced_by_customer = Order.not_canceled.where(delivery_date: range).group(:customer_id).sum(:total_cents)
    @paid_by_customer = Order.not_canceled.where(delivery_date: range).group(:customer_id).sum(:amount_paid_cents)

    @total_invoiced_cents = @invoiced_by_customer.values.sum
    @total_paid_cents = @paid_by_customer.values.sum
  end

  def show
    @orders = @customer.orders
      .not_canceled
      .where(delivery_date: @collections_period.from..@collections_period.to)
      .order(delivery_date: :desc)
      .to_a

    @invoiced_cents = @orders.sum(&:total_cents)
    @paid_cents = @orders.sum(&:amount_paid_cents)
  end

  def new
    @customer = Customer.new(active: true)
    @user = @customer.users.build
  end

  def create
    @customer = Customer.new(customer_params)
    @customer.active = true if @customer.active.nil?
    @user = @customer.users.build(user_create_params.merge(role: :customer))

    ActiveRecord::Base.transaction do
      @customer.save!
      @user.save!
    end

    redirect_to admin_customers_path, notice: "Cliente creado correctamente."
  rescue ActiveRecord::RecordInvalid
    render :new, status: :unprocessable_entity
  end

  def edit
  end

  def update
    @customer.assign_attributes(customer_params)
    @user.assign_attributes(user_update_params)

    ActiveRecord::Base.transaction do
      @customer.save!
      @user.save!
    end

    redirect_to admin_customers_path, notice: "Cliente actualizado correctamente."
  rescue ActiveRecord::RecordInvalid
    render :edit, status: :unprocessable_entity
  end

  def toggle_active
    @customer.update!(active: !@customer.active?)
    status = @customer.active? ? "reactivado" : "desactivado"
    redirect_to admin_customers_path, notice: "Cliente #{status} correctamente."
  end

  private

  def require_admin!
    redirect_to dashboard_path, alert: "No tenés permisos para acceder." unless current_user.admin?
  end

  def set_customer
    @customer = Customer.find(params[:id])
  end

  def set_user
    @user = @customer.users.first || @customer.users.build(role: :customer)
  end

  def customer_params
    params.require(:customer).permit(
      :name,
      :contact_name,
      :email,
      :phone,
      :address,
      :payment_terms,
      :internal_notes
    )
  end

  def user_create_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end

  def user_update_params
    permitted = params.require(:user).permit(:email, :password, :password_confirmation)
    return permitted if permitted[:password].present?

    permitted.except(:password, :password_confirmation)
  end
end
