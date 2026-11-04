module Retail
  # Carrito de la tienda pública. Vive en la sesión del navegador (cookie firmada y cifrada de Rails),
  # así que sobrevive a la navegación y a las recargas sin cuenta ni contraseña.
  #
  # Guarda SOLO { id de producto de la tienda => cantidad }. Nunca guarda precios ni totales: cada vez
  # que se muestra se consultan los productos publicados y sus precios vigentes, y
  # Retail::PlaceStoreOrder vuelve a hacerlo al crear el pedido. Agregar al carrito no descuenta
  # stock ni reserva nada.
  class StoreCart
    SESSION_KEY = :retail_store_cart
    MAX_QUANTITY = PlaceStoreOrder::MAX_QUANTITY
    MAX_LINES = PlaceStoreOrder::MAX_LINES

    Line = Struct.new(:product, :quantity, keyword_init: true) do
      def unit_price_cents
        product.price_cents
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
    def add(product_id, quantity)
      product = published_product(product_id)
      return "Ese producto no está disponible." unless product

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      items = contents
      key = product.id.to_s
      return "El carrito puede tener hasta #{MAX_LINES} productos distintos." if !items.key?(key) && items.size >= MAX_LINES

      total = items.fetch(key, 0) + quantity
      items[key] = [total, MAX_QUANTITY].min
      store(items)
      total > MAX_QUANTITY ? "Podés pedir hasta #{MAX_QUANTITY} unidades de cada producto por la tienda; para más, escribinos por WhatsApp." : nil
    end

    def update(product_id, quantity)
      items = contents
      key = product_id.to_s
      return "Ese producto ya no está en el carrito." unless items.key?(key)

      quantity = parse_quantity(quantity)
      return "Elegí una cantidad de 1 a #{MAX_QUANTITY}." unless quantity

      items[key] = quantity
      store(items)
      nil
    end

    def remove(product_id)
      items = contents
      items.delete(product_id.to_s)
      store(items)
    end

    def clear
      @session.delete(SESSION_KEY)
    end

    # Líneas con productos publicados y precios vigentes, en el orden en que se agregaron. Lo que dejó
    # de estar publicado se saca del carrito y su nombre queda en #dropped para avisarle al cliente.
    def lines
      @lines ||= begin
        items = contents
        products = RetailProduct.for_store.where(id: items.keys.map(&:to_i)).includes(:retail_category, primary_photo: { image_attachment: :blob }).index_by { |p| p.id.to_s }
        gone = items.keys - products.keys
        if gone.any?
          @dropped = RetailProduct.where(id: gone.map(&:to_i)).pluck(:name)
          store(items.except(*gone))
        end
        items.filter_map { |id, quantity| products[id] && Line.new(product: products[id], quantity: quantity) }
      end
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

    def published_product(id)
      return nil unless id.to_s.match?(/\A\d{1,18}\z/)

      RetailProduct.for_store.find_by(id: id.to_i)
    end

    def parse_quantity(value)
      text = value.to_s.strip
      return nil unless text.match?(/\A\d{1,3}\z/)

      quantity = text.to_i
      quantity.between?(1, MAX_QUANTITY) ? quantity : nil
    end
  end
end
