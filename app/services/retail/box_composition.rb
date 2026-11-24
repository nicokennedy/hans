module Retail
  # Composición de una caja con contenido personalizable (Etapa 2 del rediseño 2026): cuántas
  # unidades de cada sabor lleva UNA caja de una variante. Es la ÚNICA validación de composiciones:
  # la usan la tienda (agregar al carrito y mostrarlo), el checkout (Retail::PlaceStoreOrder) y los
  # pedidos del administrador (Retail::SaveOrder). El navegador solo ayuda.
  #
  # Reglas:
  #  - el producto de la variante tiene "Permitir personalizar el contenido";
  #  - la variante tiene sus unidades configuradas (content_units, 1 a 200);
  #  - cantidades enteras de 0 o más, de sabores de ESE producto;
  #  - los sabores tienen que estar habilitados (el administrador puede conservar en un pedido un
  #    sabor que se deshabilitó después: allowed_inactive_ids);
  #  - la suma es EXACTAMENTE la capacidad de la caja (se puede elegir todo de un mismo sabor).
  #
  # Formatos:
  #  - quantities: { flavor_id (Integer) => cantidad (Integer) }, sin ceros.
  #  - clave del carrito: "VARIANTE:SABORxCANT.SABORxCANT" (ej. "12:3x12.5x12"), con los sabores
  #    ordenados por id: dos cajas iguales tienen la misma clave (se suman) y dos distintas no.
  #  - snapshot (lo que guarda el pedido en retail_order_items.composition, para que los pedidos
  #    históricos no cambien): { "units" => 24, "flavors" => [{ "id", "name", "quantity" }, ...] }.
  class BoxComposition
    KEY_FORMAT = /\A(\d{1,18})(?::(\d{1,18}x\d{1,3}(?:\.\d{1,18}x\d{1,3})*))?\z/
    MAX_FLAVORS = 60

    Result = Struct.new(:errors, :quantities, :snapshot, keyword_init: true) do
      def ok?
        errors.empty?
      end
    end

    # --- Claves del carrito -------------------------------------------------------------------

    def self.valid_key?(key)
      key.to_s.match?(KEY_FORMAT)
    end

    # "12:3x12.5x12" -> [12, { 3 => 12, 5 => 12 }]; "12" -> [12, nil]; inválida -> nil.
    def self.parse_key(key)
      match = key.to_s.match(KEY_FORMAT)
      return nil unless match

      quantities = match[2]&.split(".")&.each_with_object({}) do |pair, hash|
        flavor_id, quantity = pair.split("x").map(&:to_i)
        hash[flavor_id] = hash.fetch(flavor_id, 0) + quantity
      end
      [match[1].to_i, quantities&.reject { |_, quantity| quantity.zero? }]
    end

    def self.key_for(variant_id, quantities)
      clean = Hash(quantities).select { |_, quantity| quantity.to_i.positive? }.sort_by { |flavor_id, _| flavor_id.to_i }
      return variant_id.to_s if clean.empty?

      "#{variant_id}:#{clean.map { |flavor_id, quantity| "#{flavor_id.to_i}x#{quantity.to_i}" }.join('.')}"
    end

    # --- Parámetros de formularios ------------------------------------------------------------

    # { "3" => "12", "5" => "0" } (lo que mandan los formularios) -> [{ 3 => 12 }, errores].
    # Solo acepta enteros de 0 o más escritos como números; cualquier otra cosa es un error.
    def self.quantities_from_params(raw)
      raw = raw.to_unsafe_h if raw.respond_to?(:to_unsafe_h)
      return [{}, []] if raw.blank?
      return [{}, ["La composición de la caja no es válida."]] unless raw.is_a?(Hash) && raw.size <= MAX_FLAVORS

      errors = []
      quantities = raw.each_with_object({}) do |(flavor_id, quantity), hash|
        flavor_id = flavor_id.to_s
        quantity = quantity.to_s.strip
        quantity = "0" if quantity.empty?
        unless flavor_id.match?(/\A\d{1,18}\z/) && quantity.match?(/\A\d{1,3}\z/)
          errors << "Las cantidades de cada sabor tienen que ser números enteros de 0 o más."
          next
        end
        hash[flavor_id.to_i] = hash.fetch(flavor_id.to_i, 0) + quantity.to_i
      end
      [quantities.reject { |_, quantity| quantity.zero? }, errors.uniq]
    end

    # --- Validación ---------------------------------------------------------------------------

    # variant: RetailProductVariant (con retail_product y sus flavors). quantities: { id => cant }.
    def self.validate(variant:, quantities:, allowed_inactive_ids: [])
      new(variant: variant, quantities: quantities, allowed_inactive_ids: allowed_inactive_ids).validate
    end

    def initialize(variant:, quantities:, allowed_inactive_ids: [])
      @variant = variant
      @quantities = Hash(quantities).transform_keys(&:to_i).transform_values(&:to_i)
      @allowed_inactive_ids = Array(allowed_inactive_ids).map(&:to_i)
    end

    def validate
      product = @variant&.retail_product
      return failure("Este producto no permite elegir sabores.") unless product&.customizable_content?

      units = @variant.content_units
      return failure("“#{@variant.full_name}” todavía no tiene definida la cantidad de unidades de la caja.") if units.nil?
      return failure("Las cantidades de cada sabor tienen que ser números enteros de 0 o más.") if @quantities.values.any?(&:negative?)

      chosen = @quantities.reject { |_, quantity| quantity.zero? }
      return failure("Elegí los sabores de la caja (#{units} #{units == 1 ? 'unidad' : 'unidades'}).") if chosen.empty?

      flavors = product.ordered_flavors.index_by(&:id)
      return failure("Uno de los sabores elegidos no corresponde a este producto.") if (chosen.keys - flavors.keys).any?

      unavailable = chosen.keys.map { |id| flavors[id] }.reject { |flavor| flavor.active? || @allowed_inactive_ids.include?(flavor.id) }
      if unavailable.any?
        names = unavailable.map { |flavor| "“#{flavor.name}”" }.to_sentence(words_connector: ", ", two_words_connector: " y ", last_word_connector: " y ")
        return failure("#{unavailable.size == 1 ? 'El sabor' : 'Los sabores'} #{names} ya no #{unavailable.size == 1 ? 'está disponible' : 'están disponibles'}: cambiá la composición de la caja.")
      end

      total = chosen.values.sum
      if total != units
        return failure("La caja “#{@variant.full_name}” lleva exactamente #{units} #{units == 1 ? 'unidad' : 'unidades'}: elegiste #{total}#{total < units ? " (faltan #{units - total})" : " (sobran #{total - units})"}.")
      end

      ordered = product.ordered_flavors.select { |flavor| chosen.key?(flavor.id) }
      snapshot = {
        "units" => units,
        "flavors" => ordered.map { |flavor| { "id" => flavor.id, "name" => flavor.name, "quantity" => chosen[flavor.id] } }
      }
      Result.new(errors: [], quantities: chosen, snapshot: snapshot)
    end

    # --- Presentación -------------------------------------------------------------------------

    # [["Almendra", 12], ["Maicena", 12]] desde un snapshot guardado (nunca desde los sabores actuales).
    def self.lines(snapshot)
      return [] unless snapshot.is_a?(Hash)

      Array(snapshot["flavors"]).filter_map do |flavor|
        next unless flavor.is_a?(Hash) && flavor["quantity"].to_i.positive?

        [flavor["name"].to_s, flavor["quantity"].to_i]
      end
    end

    # "Almendra × 12, Maicena × 12"
    def self.text(snapshot, separator: ", ")
      lines(snapshot).map { |name, quantity| "#{name} × #{quantity}" }.join(separator)
    end

    # { flavor_id => cantidad } de un snapshot (para precargar formularios).
    def self.quantities_from_snapshot(snapshot)
      return {} unless snapshot.is_a?(Hash)

      Array(snapshot["flavors"]).each_with_object({}) do |flavor, hash|
        hash[flavor["id"].to_i] = flavor["quantity"].to_i if flavor.is_a?(Hash) && flavor["quantity"].to_i.positive?
      end
    end

    private

    def failure(message)
      Result.new(errors: [message], quantities: {}, snapshot: nil)
    end
  end
end
