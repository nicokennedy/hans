namespace :costing do
  desc "Recalcula Product#cost_cents para todos los productos en modo recipe (auditoría/reparación)"
  task recalculate_products: :environment do
    result = Costing::RecalculateAllRecipeProducts.call

    puts "Products recalculated: #{result.recalculated}"
    puts "Errors: #{result.errors.count}"
    result.errors.each { |error| puts error }
  end
end
