module RetailCatalog
  # Principal, orden y borrado de las fotos de un producto minorista, siempre con el producto
  # bloqueado para que dos cambios simultáneos no dejen dos principales ni órdenes repetidos.
  #  - Siempre hay una principal mientras haya fotos: al borrar la principal pasa a serlo la
  #    primera de las demás.
  #  - Borrar la ÚLTIMA foto exige confirmarlo explícitamente (confirm_last), para no quedarse
  #    sin fotos por error.
  module PhotoArrangement
    module_function

    def make_primary(photo)
      with_lock(photo.retail_product) do |product|
        product.photos.where(primary: true).where.not(id: photo.id).update_all(primary: false, updated_at: Time.current)
        photo.update!(primary: true)
      end
      nil
    end

    # direction: -1 (antes) / +1 (después), entre las fotos secundarias.
    def move(photo, direction)
      return "La foto principal siempre va primero." if photo.primary?

      with_lock(photo.retail_product) do |product|
        ordered = product.photos.secondary.order(:position, :id).to_a
        index = ordered.index { |p| p.id == photo.id }
        target = index + direction
        next if target.negative? || target >= ordered.size

        ordered[index], ordered[target] = ordered[target], ordered[index]
        ordered.each_with_index { |p, i| p.update_columns(position: i + 1, updated_at: Time.current) if p.position != i + 1 }
      end
      nil
    end

    # Devuelve un mensaje de error o nil si se borró.
    def destroy(photo, confirm_last: false)
      error = nil
      with_lock(photo.retail_product) do |product|
        if product.photos.count == 1 && !confirm_last
          error = "Es la única foto del producto: confirmá que querés dejarlo sin fotos."
          next
        end

        was_primary = photo.primary?
        photo.destroy!
        if was_primary && (next_primary = product.photos.order(:position, :id).first)
          next_primary.update!(primary: true)
        end
      end
      error
    end

    def with_lock(product)
      RetailProductPhoto.transaction do
        product.lock!
        yield product
      end
    end
  end
end
