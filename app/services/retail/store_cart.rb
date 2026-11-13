module Retail
  # Carrito de la tienda pública. Vive en la sesión del navegador (cookie firmada y cifrada de Rails),
  # así que sobrevive a la navegación y a las recargas sin cuenta ni contraseña.
  #
  # Guarda SOLO { id de VARIANTE de la tienda => cantidad } (la variante es el tamaño o presentación
  # elegido; los productos simples tienen una sola). Nunca guarda precios ni totales: cada vez que se
  # muestra se consultan las variantes publicadas y sus precios vigentes, y Retail::PlaceStoreOrder
  # vuelve a hacerlo al crear el pedido. Agregar al carrito no descuenta stock ni reserva nada: la
  # reserva se hace al enviar el pedido.
  #
  # La clave de sesión es nueva (v2): los carritos anteriores guardaban ids de producto, que no son
  # ids de variante, así que se descartan en vez de interpretarse mal.
  class StoreCart
    SESSION_KEY = :retail_store_cart_v2
    MAX_QUANTITY = PlaceStoreOrder::MAX_QUANTITY
    MAX_LINES = PlaceStoreOrder::MAX_LINES

    Line = Struct.new(:variant, :quantity, keyword_init: true) do
      def product
        variant.retail_product
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
    end

    attr_reader :dropped

    def initialize(session)
      @session = session
      @dropped = []
    end

    # Cantidades guardadas, ya normalizadas: { "12" => 2 }.
    def contents
      raw = @session[SESSION_KEY]
      raw = {} unless raw.is_a?(Hash)
      raw.each_with_object({}) do |(id, quantity), clean|
        next unless id.to_s.match?(/\A\d{1,18}\z/)

        quantity = quantity.to_i
        clean[id.to_s] = quantity.clamp(1, MAX_QUANTITY) if quantity.positive?
      end.first(MAX_LINES).to_h
    end

    # Devuelve nil si salió bien o el mensaje para el cliente.
    def add(variant_id, quantity)
      variant = purchasable_variant(variant_id)
      return "Ese producto no está disponible." unless variant

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      items = contents
      key = variant.id.to_s
      return "El carrito puede tener hasta #{MAX_LINES} productos distintos." if !items.key?(key) && items.size >= MAX_LINES

      total = items.fetch(key, 0) + quantity
      limit = variant.limited_stock? ? [variant.stock_quantity, MAX_QUANTITY].min : MAX_QUANTITY
      items[key] = [total, limit].min
      store(items)
      return OnlineStock::Insufficient.new(variant, variant.stock_quantity, total).message + " Dejamos #{items[key]} en tu carrito." if variant.limited_stock? && total > variant.stock_quantity

      total > MAX_QUANTITY ? "Podés pedir hasta #{MAX_QUANTITY} unidades de cada producto por la tienda; para más, escribinos por WhatsApp." : nil
    end

    def update(variant_id, quantity)
      items = contents
      key = variant_id.to_s
      return "Ese producto ya no está en el carrito." unless items.key?(key)

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      items[key] = quantity
      store(items)
      nil
    end

    def remove(variant_id)
      items = contents
      items.delete(variant_id.to_s)
      store(items)
    end

    def clear
      @session.delete(SESSION_KEY)
    end

    # Líneas con variantes que se pueden comprar y precios vigentes, en el orden en que se agregaron. Lo
    # que dejó de estar publicado, se deshabilitó o se agotó se saca del carrito y su nombre queda en
    # #dropped para avisarle al cliente.
    def lines
      @lines ||= begin
        items = contents
        variants = self.class.available_variants.where(id: items.keys.map(&:to_i))
                       .includes(retail_product: [:retail_category, { primary_photo: { image_attachment: :blob } }]).index_by { |v| v.id.to_s }
        gone = items.keys - variants.keys
        if gone.any?
          @dropped = RetailProductVariant.includes(:retail_product).where(id: gone.map(&:to_i)).map(&:full_name)
          store(items.except(*gone))
        end
        items.filter_map { |id, quantity| variants[id] && Line.new(variant: variants[id], quantity: quantity) }
      end
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

      self.class.available_variants.includes(:retail_product).find_by(id: id.to_i)
    end

    def parse_quantity(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A\d{1,3}\z/)

      quantity = text.to_i
      quantity.between?(1, MAX_QUANTITY) ? quantity : nil
    end
  end
end
