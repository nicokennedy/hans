namespace :stock do
  desc "Concilia salidas de stock vencidas (delivery_date pasada, o de hoy después de las 13:00). Idempotente — pensado para correr vía Heroku Scheduler alrededor de las 13:00 hora local, pero seguro de correr en cualquier momento y las veces que haga falta."
  task reconcile_due: :environment do
    result = Stock::DispatchReconciler.reconcile_due!

    puts "Orders reconciled: #{result.reconciled}"
    puts "Errors: #{result.errors.count}"
    result.errors.each { |error| puts error }
  end
end
