module Retail
  # Carrito de la tienda pública. Vive en la sesión del navegador (cookie firmada y cifrada de Rails),
  # así que sobrevive a la navegación y a las recargas sin cuenta ni contraseña.
  #
  # Guarda SOLO { clave de línea => cantidad }. La clave es el id de la VARIANTE (tamaño o
  # presentación; los productos simples tienen una sola) o, para cajas con contenido personalizable,
  # la variante + su composición en formato compacto ("12:3x12.5x12", ver Retail::BoxComposition):
  # así dos cajas con distinta composición son líneas separadas y el carrito entra en la cookie.
  # Las claves de los carritos anteriores (solo la variante) siguen siendo válidas.
  #
  # Nunca guarda precios ni totales: cada vez que se muestra se consultan las variantes publicadas y
  # sus precios vigentes, y Retail::PlaceStoreOrder vuelve a hacerlo al crear el pedido. Agregar al carrito no descuenta stock ni reserva nada: la
  # reserva se hace al enviar el pedido.
  #
  # La clave de sesión es nueva (v2): los carritos anteriores guardaban ids de producto, que no son
  # ids de variante, así que se descartan en vez de interpretarse mal.
  class StoreCart
    SESSION_KEY = :retail_store_cart_v2
    MAX_QUANTITY = PlaceStoreOrder::MAX_QUANTITY
    MAX_LINES = PlaceStoreOrder::MAX_LINES
    # El carrito vive en la cookie de sesión, que el navegador limita a 4 KB (cifrada, con el resto de
    # la sesión). Las claves de las cajas personalizables ocupan más que un id: con muchas cajas
    # distintas de productos con muchos sabores el carrito podría no entrar. Este tope (medido con el
    # peor caso en los tests) deja margen para el resto de la sesión: si una caja nueva lo pasaría, no
    # se agrega y se avisa, en vez de romper la página.
    MAX_STORED_BYTES = 1800
    FULL_MESSAGE = "Tu carrito llegó al máximo de cajas distintas que podemos guardar. Finalizá este pedido o escribinos por WhatsApp para sumar más.".freeze
    FULL_EDIT_MESSAGE = "No pudimos guardar el cambio: tu carrito llegó al máximo de cajas distintas que podemos guardar. La caja quedó como estaba; podés finalizar el pedido o escribirnos por WhatsApp.".freeze

    # Una línea del carrito. key identifica la línea: el id de la variante ("12") o, para una caja
    # con contenido personalizable, la variante + su composición ("12:3x12.5x12", ver
    # Retail::BoxComposition). quantity es la cantidad de productos (o de cajas iguales).
    # problem: por qué esta línea no se puede pedir así (un sabor se deshabilitó, la caja cambió de
    # unidades...): la línea NO se saca del carrito; el cliente la corrige o la quita.
    Line = Struct.new(:key, :variant, :quantity, :quantities, :composition, :problem, keyword_init: true) do
      def product
        variant.retail_product
      end

      def box?
        !quantities.nil?
      end

      def unit_price_cents
        variant.price_cents
      end

      # Stock limitado que no alcanza para la cantidad del carrito (se avisa; el checkout lo rechaza).
      def short_stock?
        variant.limited_stock? && variant.stock_quantity < quantity
      end

      def line_total_cents
        unit_price_cents * quantity
      end

      # [["Almendra", 12], ...] de lo que eligió el cliente (con los nombres actuales de los sabores).
      def composition_lines
        if composition
          BoxComposition.lines(composition)
        else
          flavors = product.ordered_flavors.index_by(&:id)
          Hash(quantities).filter_map { |id, quantity| flavors[id] && [flavors[id].name, quantity] }
        end
      end
    end

    attr_reader :dropped

    def initialize(session)
      @session = session
      @dropped = []
    end

    # Cantidades guardadas, ya normalizadas: { "12" => 2, "12:3x12.5x12" => 1 }.
    def contents
      raw = @session[SESSION_KEY]
      raw = {} unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(key, quantity), clean|
        next unless BoxComposition.valid_key?(key)

        quantity = quantity.to_i
        clean[key.to_s] = quantity.clamp(1, MAX_QUANTITY) if quantity.positive?
      end.first(MAX_LINES).to_h
    end

    # Devuelve nil si salió bien o el mensaje para el cliente. flavors: los parámetros del selector
    # de sabores ({ "id de sabor" => cantidad }); solo para productos con contenido personalizable.
    def add(variant_id, quantity, flavors: nil)
      variant = purchasable_variant(variant_id)
      return "Ese producto no está disponible." unless variant

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      key, error = line_key(variant, flavors)
      return error if error

      items = contents
      return "El carrito puede tener hasta #{MAX_LINES} productos distintos." if !items.key?(key) && items.size >= MAX_LINES

      add_to(items, key, variant, quantity)
    end

    # Cambia la composición (o la presentación) de una caja que ya está en el carrito, conservando la
    # cantidad de cajas. Si ya había una caja igual, se suman. Devuelve nil o el mensaje para el cliente.
    def replace(old_key, variant_id, flavors:)
      items = contents
      old_key = old_key.to_s
      return "Esa caja ya no está en el carrito." unless items.key?(old_key)

      variant = purchasable_variant(variant_id)
      return "Ese producto no está disponible." unless variant
      return "Ese producto no permite elegir sabores." unless variant.customizable?

      key, error = line_key(variant, flavors)
      return error if error

      original = items.dup
      quantity = items.delete(old_key)
      if key != old_key && !items.key?(key) && items.size >= MAX_LINES
        return "El carrito puede tener hasta #{MAX_LINES} productos distintos."
      end

      message = add_to(items, key, variant, quantity)
      # Si la caja nueva no se pudo guardar (stock, tope del carrito), la anterior queda como estaba.
      if message && !contents.key?(key)
        store(original)
        return FULL_EDIT_MESSAGE if message == FULL_MESSAGE
      end
      message
    end

    def update(key, quantity)
      items = contents
      key = key.to_s
      return "Ese producto ya no está en el carrito." unless items.key?(key)

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      items[key] = quantity
      store(items)
      nil
    end

    def remove(key)
      items = contents
      items.delete(key.to_s)
      store(items)
    end

    def clear
      @session.delete(SESSION_KEY)
    end

    # Líneas con variantes que se pueden comprar y precios vigentes, en el orden en que se agregaron. Lo
    # que dejó de estar publicado, se deshabilitó o se agotó se saca del carrito y su nombre queda en
    # #dropped para avisarle al cliente. Una caja cuya composición ya no es válida (un sabor
    # deshabilitado, otra cantidad de unidades) se queda en el carrito con #problem, para corregirla.
    def lines
      @lines ||= begin
        items = contents
        parsed = items.keys.index_with { |key| BoxComposition.parse_key(key) }
        variant_ids = parsed.values.map(&:first).uniq
        variants = self.class.available_variants.where(id: variant_ids)
                       .includes(retail_product: [:retail_category, :flavors, { primary_photo: { image_attachment: :blob } }]).index_by(&:id)
        gone = items.keys.reject { |key| variants.key?(parsed[key].first) }
        if gone.any?
          @dropped = RetailProductVariant.includes(:retail_product).where(id: gone.map { |key| parsed[key].first }).map(&:full_name).uniq
          store(items.except(*gone))
        end
        items.filter_map do |key, quantity|
          variant_id, quantities = parsed[key]
          variant = variants[variant_id]
          next unless variant

          build_line(key, variant, quantity, quantities)
        end
      end
    end

    # ¿Hay cajas que el cliente tiene que corregir antes de finalizar?
    def problems?
      lines.any?(&:problem)
    end

    # Variantes que la tienda vende ahora: habilitadas, con stock (o sin límite) y de un producto publicado.
    def self.available_variants
      RetailProductVariant.purchasable.where(retail_product_id: RetailProduct.for_store.select(:id))
    end

    def subtotal_cents
      lines.sum(&:line_total_cents)
    end

    def count
      contents.values.sum
    end

    def empty?
      contents.empty?
    end

    private

    def build_line(key, variant, quantity, quantities)
      problem = nil
      composition = nil
      if variant.customizable?
        if quantities.nil?
          problem = "Elegí los sabores de esta caja."
        else
          result = BoxComposition.validate(variant: variant, quantities: quantities)
          result.ok? ? composition = result.snapshot : problem = result.errors.first
        end
      elsif quantities
        problem = "Este producto ya no permite elegir sabores: quitalo y agregalo de nuevo."
      end
      Line.new(key: key, variant: variant, quantity: quantity, quantities: quantities, composition: composition, problem: problem)
    end

    # Clave de la línea: la variante sola o la variante + composición validada.
    def line_key(variant, flavors)
      return [variant.id.to_s, nil] unless variant.customizable?

      quantities, errors = BoxComposition.quantities_from_params(flavors)
      return [nil, errors.first] if errors.any?

      result = BoxComposition.validate(variant: variant, quantities: quantities)
      return [nil, result.errors.first] unless result.ok?

      [BoxComposition.key_for(variant.id, result.quantities), nil]
    end

    # Suma la cantidad a la línea respetando el máximo y el stock limitado de la variante (que se
    # comparte entre todas las cajas de esa variante, aunque tengan composiciones distintas).
    def add_to(items, key, variant, quantity)
      others = items.except(key).sum { |other, amount| BoxComposition.parse_key(other)&.first == variant.id ? amount : 0 }
      total = items.fetch(key, 0) + quantity
      limit = variant.limited_stock? ? [variant.stock_quantity - others, MAX_QUANTITY].min : MAX_QUANTITY
      if limit <= 0
        store(items)
        return OnlineStock::Insufficient.new(variant, variant.stock_quantity, total + others).message
      end
      if !items.key?(key) && stored_bytes(items.merge(key => limit)) > MAX_STORED_BYTES
        store(items)
        return FULL_MESSAGE
      end

      items[key] = [total, limit].min
      store(items)
      if variant.limited_stock? && total + others > variant.stock_quantity
        return OnlineStock::Insufficient.new(variant, variant.stock_quantity, total + others).message + " Dejamos #{items[key]} en tu carrito."
      end

      total > MAX_QUANTITY ? "Podés pedir hasta #{MAX_QUANTITY} unidades de cada producto por la tienda; para más, escribinos por WhatsApp." : nil
    end

    def stored_bytes(items)
      items.to_json.bytesize
    end

    def store(items)
      @lines = nil
      if items.empty?
        clear
      else
        @session[SESSION_KEY] = items
      end
    end

    def purchasable_variant(id)
      return nil unless id.to_s.match?(/\A\d{1,18}\z/)

      self.class.available_variants.includes(retail_product: :flavors).find_by(id: id.to_i)
    end

    def parse_quantity(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A\d{1,3}\z/)

      quantity = text.to_i
      quantity.between?(1, MAX_QUANTITY) ? quantity : nil
    end
  end
end
