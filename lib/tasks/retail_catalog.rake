namespace :retail_catalog do
  desc "Verifica Cloudflare R2 (sube, lee y borra un objeto de prueba) antes de habilitar las fotos"
  task check_storage: :environment do
    RetailCatalog::PhotoStorage.check_r2!
    puts "OK: Cloudflare R2 responde (bucket #{ENV['R2_BUCKET']}). Ya se puede configurar RETAIL_PHOTOS_ENABLED=true."
  rescue StandardError => e
    puts "ERROR: R2 no está listo: #{e.class}: #{e.message}"
    exit 1
  end
end
