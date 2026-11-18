require "csv"

# Importación de direcciones de clientes desde el Excel de Administración → Clientes →
# Exportar clientes. Ver docs/CLIENTES_DIRECCIONES.md.
#
#   Dry run (no escribe nada):
#     bin/rails hans:customer_addresses:check FILE=ruta/al/archivo.xlsx
#   Importación real (una transacción, todo o nada):
#     bin/rails hans:customer_addresses:import FILE=ruta/al/archivo.xlsx CONFIRMAR=SI
#
# En Heroku el archivo no está en el dyno: se manda por la entrada estándar en base64
# con FILE=- (ver el documento).
namespace :hans do
  namespace :customer_addresses do
    desc "Dry run de la importación de direcciones de clientes (no escribe nada). FILE=archivo.xlsx o FILE=- (base64 por stdin)"
    task check: :environment do
      CustomerAddressesTask.run(apply: false)
    end

    desc "Importa las direcciones de clientes en una transacción. Requiere FILE y CONFIRMAR=SI"
    task import: :environment do
      abort "Falta CONFIRMAR=SI. Corré primero el dry run (hans:customer_addresses:check) y revisalo." unless ENV["CONFIRMAR"] == "SI"

      CustomerAddressesTask.run(apply: true)
    end
  end
end

module CustomerAddressesTask
  module_function

  def run(apply:)
    data = read_file
    result = Customers::AddressImport.new(data).call(apply: apply)
    print_report(result, apply: apply)
    write_csv(result) if ENV["REPORT"].present?
  rescue Customers::XlsxRows::Error, Customers::AddressImport::Aborted => e
    abort "ERROR: #{e.message}"
  end

  def read_file
    path = ENV["FILE"].to_s
    abort "Falta FILE=ruta/al/archivo.xlsx (o FILE=- para leer el archivo en base64 por stdin)." if path.blank?
    return Base64.decode64($stdin.read) if path == "-"

    abort "No existe el archivo #{path}." unless File.exist?(path)
    File.binread(path)
  end

  def print_report(result, apply:)
    puts
    puts(apply ? "=== IMPORTACIÓN DE DIRECCIONES (#{Rails.env}) ===" : "=== DRY RUN: no se escribe nada (#{Rails.env}) ===")
    puts "Filas leídas: #{result.rows_read}"
    puts

    if result.changes.any?
      puts(apply ? "Cambios aplicados:" : "Cambios que se aplicarían:")
      result.changes.group_by(&:customer_id).each do |id, changes|
        puts "  ##{id} #{changes.first.customer_name} (fila #{changes.first.row})"
        changes.each { |c| puts "     #{c.field.header}: «#{c.from}» → «#{c.to}»" }
      end
    else
      puts "No hay cambios para aplicar."
    end

    section("Filas con errores (no se importan)", result.errors)
    section("Avisos", result.warnings)
    section("Datos completados en campos que todavía no existen en HANS (no se guardan)", result.pending)

    puts
    puts "Resumen: #{result.customers_to_update} clientes y #{result.changes.size} campos #{apply ? 'actualizados' : 'a actualizar'} · " \
         "#{result.errors.size} filas con errores · #{result.warnings.size} avisos · #{result.pending.size} datos pendientes de campo."
    puts(apply ? "Listo: la importación se hizo en una sola transacción." : "Dry run terminado: no se modificó nada.")
  end

  def section(title, issues)
    return if issues.empty?

    puts
    puts "#{title}:"
    issues.each { |i| puts "  Fila #{i.row}#{i.customer_id ? " · ##{i.customer_id}" : ''}: #{i.message}" }
  end

  def write_csv(result)
    CSV.open(ENV["REPORT"], "w") do |csv|
      csv << %w[fila cliente_id cliente campo valor_anterior valor_nuevo]
      result.changes.each { |c| csv << [c.row, c.customer_id, c.customer_name, c.field.header, c.from, c.to] }
    end
    puts "Informe guardado en #{ENV['REPORT']}"
  end
end
