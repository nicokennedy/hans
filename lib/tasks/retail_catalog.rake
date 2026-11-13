namespace :retail_catalog do
  desc "Verifica Cloudflare R2 (sube, lee y borra un objeto de prueba) antes de habilitar las fotos"
  task check_storage: :environment do
    RetailCatalog::PhotoStorage.check_r2!
    puts "OK: Cloudflare R2 responde (bucket #{ENV['R2_BUCKET']}). Ya se puede configurar RETAIL_PHOTOS_ENABLED=true."
  rescue StandardError => e
    puts "ERROR: R2 no está listo: #{e.class}: #{e.message}"
    exit 1
  end

  # Importa el catálogo exportado de TakePedido. SIMULA por defecto (todo se deshace al final).
  #   bin/rails "retail_catalog:import_takepedido[ruta/al/archivo.csv]"
  #   heroku run --no-tty -a hans -- bin/rails "retail_catalog:import_takepedido[-]" < archivo.csv   (lee de la entrada)
  # APPLY=1 guarda de verdad. UPDATE_EXISTING=1 además aplica las diferencias a productos que ya existían.
  desc "Importa el CSV de TakePedido a la tienda minorista (simula salvo APPLY=1)"
  task :import_takepedido, [:path] => :environment do |_, args|
    path = args[:path].presence || abort("Indicá el archivo: retail_catalog:import_takepedido[archivo.csv] (o [-] para leer de la entrada)")
    importer = if path == "-"
                 RetailCatalog::TakepedidoImport.new(CSV.parse($stdin.read.delete_prefix("\uFEFF"), headers: true).map(&:to_h))
               else
                 RetailCatalog::TakepedidoImport.read(path)
               end
    apply = ENV["APPLY"] == "1"
    importer.call(dry_run: !apply, update_existing: ENV["UPDATE_EXISTING"] == "1")
    puts RetailCatalog::TakepedidoImport::Report.new(importer).text
    puts apply ? "\nIMPORTACIÓN GUARDADA." : "\nSIMULACIÓN: no se guardó nada (APPLY=1 para importar)."
  end
end
