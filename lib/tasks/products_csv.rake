namespace :hans do
  desc "Export products to db/products.csv"
  task export_products: :environment do
    path = Products::CsvExporter.new.call

    puts "Exportación terminada."
    puts "Archivo: #{path}"
  end

  desc "Preview canonical products import from db/products.csv"
  task preview_products_import: :environment do
    result = Products::CsvImporter.new(dry_run: true).call

    puts "Previsualización terminada. No se guardaron cambios."
    puts "Productos a crear: #{result.created}"
    puts "Productos a actualizar: #{result.updated}"
    puts "Errores: #{result.errors.count}"
    result.errors.each { |error| puts error }
  end

  desc "Import canonical products from db/products.csv"
  task import_products_canonical: :environment do
    result = Products::CsvImporter.new.call

    puts "Importación terminada."
    puts "Productos creados: #{result.created}"
    puts "Productos actualizados: #{result.updated}"
    puts "Errores: #{result.errors.count}"
    result.errors.each { |error| puts error }
  end
end
