class Admin::Administration::DashboardController < Admin::Administration::BaseController
  def show
    # Las ocurrencias de gastos recurrentes que ya corresponden se generan al entrar (es
    # idempotente: nunca duplica). Un error acá no debe romper el resumen.
    begin
      Finance::GenerateRecurringExpenses.call
    rescue StandardError => e
      Rails.logger.error("No se pudieron generar los gastos recurrentes: #{e.message}")
    end

    @summary = Finance::Summary.new(year: params[:year], month: params[:month])
  end
end
