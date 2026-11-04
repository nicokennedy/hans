require "test_helper"
require_relative "../../support/retail_catalog_helpers"

# Fotos del catálogo minorista: subida múltiple validada por contenido y tamaño, sin duplicados,
# principal explícita, orden, reemplazo, borrado protegido y bloqueo sin almacenamiento.
class RetailCatalog::PhotosTest < ActiveSupport::TestCase
  include RetailCatalogHelpers

  setup do
    @product = catalog_product
  end

  def upload(*names)
    RetailCatalog::PhotoUpload.add(product: @product, files: names.map { |n| n.is_a?(String) ? image_upload(n) : n })
  end

  test "sube varias fotos a la vez (JPEG, PNG y WebP); la primera queda como principal" do
    result = upload("pixel.png", "pixel.jpg", "pixel.webp")

    assert result.ok?, result.errors.inspect
    photos = @product.photos.reload
    assert_equal 3, photos.size
    assert_equal [true, false, false], photos.map(&:primary)
    assert_equal %w[image/png image/jpeg image/webp], photos.map { |p| p.image.blob.content_type }
    assert_equal [1, 2, 3], photos.map(&:position)
    assert_equal "pixel.webp", photos.last.image.filename.to_s
  end

  test "valida el contenido real, no la extensión: rechaza texto con .jpg y PDF; guarda las válidas del mismo envío" do
    result = upload("not_an_image.jpg", "pixel.png", "document.pdf")

    assert_equal 1, result.saved.size
    assert_equal ["not_an_image.jpg: no es una imagen JPEG, PNG o WebP válida.", "document.pdf: no es una imagen JPEG, PNG o WebP válida."], result.errors
    assert_equal 1, @product.photos.count
  end

  test "el tipo guardado sale del contenido aunque el navegador declare otro" do
    result = RetailCatalog::PhotoUpload.add(product: @product, files: [image_upload("pixel.png", content_type: "image/jpeg")])
    assert result.ok?
    assert_equal "image/png", @product.photos.first.image.blob.content_type
  end

  test "rechaza archivos de más de 5 MB" do
    result = upload(oversized_png)
    assert_equal 0, result.saved.size
    assert_match "supera el máximo de 5 MB", result.errors.first
    assert_equal 0, ActiveStorage::Blob.count
  end

  test "no repite la misma imagen en un producto (ni en el mismo envío ni después)" do
    result = upload("pixel.png", "pixel.png")
    assert_equal 1, result.saved.size
    assert_match "ya está cargada", result.errors.first

    later = upload("pixel.png")
    assert_equal 0, later.saved.size
    assert_equal 1, @product.photos.count

    other = catalog_product
    assert RetailCatalog::PhotoUpload.add(product: other, files: [image_upload("pixel.png")]).ok?, "otro producto sí puede usar la misma imagen"
  end

  test "sin archivos: pide elegir al menos uno" do
    assert_equal ["Elegí al menos una imagen."], upload.errors
  end

  test "elegir la principal deja una sola" do
    upload("pixel.png", "red.png", "pixel.jpg")
    third = @product.photos.find_by(position: 3)

    RetailCatalog::PhotoArrangement.make_primary(third)
    assert_equal [third.id], @product.photos.where(primary: true).pluck(:id)
    assert_equal third, @product.reload.primary_photo
  end

  test "ordena las fotos secundarias y la principal va siempre primero" do
    upload("pixel.png", "red.png", "pixel.jpg", "pixel.webp")
    primary, a, b, c = @product.photos.reload.to_a

    RetailCatalog::PhotoArrangement.move(c, -1)
    assert_equal [primary, a, c, b], @product.photos.reload.to_a
    RetailCatalog::PhotoArrangement.move(a, 1)
    assert_equal [primary, c, a, b], @product.photos.reload.to_a
    assert_equal "La foto principal siempre va primero.", RetailCatalog::PhotoArrangement.move(primary, 1)
    assert_nil RetailCatalog::PhotoArrangement.move(c, -1), "mover la primera hacia atrás no hace nada"
    assert_equal [primary, c, a, b], @product.photos.reload.to_a
  end

  test "reemplazar cambia el archivo y conserva su lugar; no acepta una imagen repetida" do
    upload("pixel.png", "red.png")
    primary = @product.photos.find_by(primary: true)
    old_blob = primary.image.blob

    result = RetailCatalog::PhotoUpload.replace(photo: primary, file: image_upload("pixel.webp"))
    assert result.ok?, result.errors.inspect
    primary.reload
    assert primary.primary?
    assert_equal 1, primary.position
    assert_equal "image/webp", primary.image.blob.content_type
    assert_not_equal old_blob.id, primary.image.blob.id

    repeated = RetailCatalog::PhotoUpload.replace(photo: primary, file: image_upload("red.png"))
    assert_match "ya está cargada", repeated.errors.first
    invalid = RetailCatalog::PhotoUpload.replace(photo: primary, file: image_upload("not_an_image.jpg"))
    assert_match "no es una imagen", invalid.errors.first
    assert_equal "image/webp", primary.reload.image.blob.content_type
  end

  test "borrar la principal pasa la principal a la siguiente; la última foto exige confirmación" do
    upload("pixel.png", "red.png")
    primary, other = @product.photos.reload.to_a

    assert_nil RetailCatalog::PhotoArrangement.destroy(primary)
    assert other.reload.primary?

    assert_match "única foto", RetailCatalog::PhotoArrangement.destroy(other)
    assert RetailProductPhoto.exists?(other.id)
    assert_nil RetailCatalog::PhotoArrangement.destroy(other, confirm_last: true)
    assert_empty @product.photos.reload
  end

  test "si el almacenamiento no está habilitado no acepta fotos (no se aceptan fotos que se perderían)" do
    RetailCatalog::PhotoStorage.stub(:enabled?, false) do
      result = upload("pixel.png")
      assert_equal 0, result.saved.size
      assert_match "Cloudflare R2", result.errors.first
    end
    assert_equal 0, @product.photos.count
    assert_equal 0, ActiveStorage::Blob.count
  end

  test "borrar el producto borra sus fotos" do
    upload("pixel.png", "red.png")
    assert_difference "RetailProductPhoto.count", -2 do
      @product.destroy!
    end
  end
end
