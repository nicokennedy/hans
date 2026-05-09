require "csv"

namespace :hans do
  desc "Import products from db/imports/products.csv"
  task import_products: :environment do
    path = Rails.root.join("db/imports/products.csv")

    unless File.exist?(path)
      puts "No existe el archivo: #{path}"
      exit
    end

    category_names = {
      "AL" => "Alfajores",
      "BU" => "Budines",
      "CO" => "Cookies",
      "CU" => "Cuadrados",
      "MA" => "Macarons",
      "MI" => "Muffins",
      "ZF" => "Fríos",
      "OT" => "Otros",
      "PO" => "Postres"
    }

    def parse_money(value)
      value.to_s
        .gsub("$", "")
        .gsub(".", "")
        .gsub(",", ".")
        .strip
        .to_f
    end

    created_or_updated = 0
    skipped = 0

    CSV.foreach(path, headers: false).with_index do |row, index|
      name = row[1].to_s.strip
      cost = parse_money(row[2])
      price = parse_money(row[3])
      category_code = row[9].to_s.strip

      next if name.blank?
      next if name.upcase == "NOMBRE"
      next if price <= 0

      public_category_name = category_names[category_code] || "Otros"

      category = Category.find_or_create_by!(name: public_category_name) do |c|
        c.active = true if c.respond_to?(:active=)
        c.position = category_names.keys.index(category_code).to_i + 1 if c.respond_to?(:position=)
      end

      product = Product.find_or_initialize_by(name: name)

      product.category = category
      product.internal_category = category_code
      product.price_cents = (price * 100).round
      product.cost_cents = (cost * 100).round
      product.active = true if product.respond_to?(:active=)
      product.position = index if product.respond_to?(:position=)

      product.save!

      created_or_updated += 1
    rescue => e
      skipped += 1
      puts "Fila #{index + 1} salteada: #{e.message}"
    end

    puts "Importación terminada."
    puts "Productos creados/actualizados: #{created_or_updated}"
    puts "Filas salteadas: #{skipped}"
  end
end