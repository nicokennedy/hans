# Cajas con contenido personalizable (Etapa 2): un "Mix de alfajores" con Caja x 8 / x 12 / x 24 y
# los sabores Almendra, Maicena y Cacao, listo para la tienda (con foto principal).
module BoxHelpers
  def create_mix_box(category: nil, name: "Mix de alfajores #{rand(1_000_000)}", publish: true)
    category ||= RetailCategory.create!(name: "Cajitas #{rand(1_000_000)}", active: true)
    product = RetailProduct.create!(
      name: name, retail_category: category, active: true, customizable_content: true,
      variants_attributes: [
        { name: "Caja x 8", position: 1, price: "8.000", content_units: 8 },
        { name: "Caja x 12", position: 2, price: "11.000", content_units: 12 },
        { name: "Caja x 24", position: 3, price: "20.000", content_units: 24 }
      ],
      flavors_attributes: [{ name: "Almendra", position: 1 }, { name: "Maicena", position: 2 }, { name: "Cacao", position: 3 }]
    )
    RetailCatalog::PhotoUpload.add(product: product, files: [image_upload("pixel.png")]) if publish
    product.reload
  end

  def box_variant(product, units)
    product.variants.find { |v| v.content_units == units }
  end

  def flavor(product, name)
    product.flavors.find { |f| f.name == name }
  end

  # { "id" => "cantidad" } como lo manda el formulario.
  def flavor_params(product, quantities)
    quantities.to_h { |name, quantity| [flavor(product, name).id.to_s, quantity.to_s] }
  end
end
