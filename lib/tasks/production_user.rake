namespace :hans do
  desc "Crea o actualiza (de forma idempotente) el usuario de solo lectura del equipo de producción. " \
       "Requiere PRODUCTION_PASSWORD como variable de entorno. Opcional: PRODUCTION_EMAIL (default produccion@hans.com), PRODUCTION_NAME."
  task create_production_user: :environment do
    password = ENV["PRODUCTION_PASSWORD"]

    if password.blank?
      abort "Falta la variable de entorno PRODUCTION_PASSWORD. No se crea el usuario sin ella (no se permite una contraseña hardcodeada)."
    end

    email = ENV["PRODUCTION_EMAIL"].presence || "produccion@hans.com"
    display_name = ENV["PRODUCTION_NAME"].presence || "Equipo de Producción"

    user = User.find_or_initialize_by(email: email)
    user.password = password
    user.role = "production"
    user.save!

    puts "Usuario de producción listo: #{user.email} (#{display_name}), rol=#{user.role}"
  end
end
