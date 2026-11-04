# Datos comunes de los tests del catálogo minorista (Tienda Minorista → Productos / Categorías).
module RetailCatalogHelpers
  FILES = Rails.root.join("test/fixtures/files/retail_catalog")

  def catalog_category(name = "Cookies #{rand(1_000_000)}", **attrs)
    RetailCategory.create!(name: name, **attrs)
  end

  def catalog_product(name = "Box de cookies #{rand(1_000_000)}", category: nil, price: "4.500", **attrs)
    RetailProduct.create!(name: name, retail_category: category || catalog_category, price: price, **attrs)
  end

  def image_upload(name, content_type: nil)
    Rack::Test::UploadedFile.new(FILES.join(name), content_type || Marcel::MimeType.for(name: name))
  end

  # Archivo con cabecera PNG válida y más de 5 MB.
  def oversized_png
    file = Tempfile.new(["grande", ".png"])
    file.binmode
    file.write("\x89PNG\r\n\x1A\n".b + ("\0".b * (5.megabytes + 1)))
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "image/png")
  end
end
