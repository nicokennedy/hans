class Admin::Administration::ExpenseCategoriesController < Admin::Administration::BaseController
  before_action :set_category, only: [:edit, :update, :toggle_active]

  def index
    @categories = ExpenseCategory.ordered
    @usage = Expense.group(:expense_category_id).count
  end

  def new
    @category = ExpenseCategory.new(position: (ExpenseCategory.maximum(:position) || 0) + 1)
  end

  def create
    @category = ExpenseCategory.new(category_params)

    if @category.save
      redirect_to admin_administration_expense_categories_path, notice: "Categoría creada."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @category.update(category_params)
      redirect_to admin_administration_expense_categories_path, notice: "Categoría actualizada."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def toggle_active
    @category.update!(active: !@category.active?)
    redirect_to admin_administration_expense_categories_path, notice: @category.active? ? "Categoría reactivada." : "Categoría desactivada. Los gastos ya cargados la conservan."
  end

  private

  def set_category
    @category = ExpenseCategory.find(params[:id])
  end

  def category_params
    params.require(:expense_category).permit(:name, :position, :active)
  end
end
