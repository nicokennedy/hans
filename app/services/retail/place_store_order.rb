module Retail
  # Alta de un pedido de la TIENDA ONLINE: la única entrada del checkout público. Todo se valida y
  # se calcula en el servidor antes de crear nada:
  #  - datos del comprador: nombre, celular con WhatsApp, email y forma de pago (transferencia o
  #    efectivo: solo indica cómo quiere pagar, nunca registra un pago);
  #  - productos: el carrito trae SOLO claves de línea (id de VARIANTE de la tienda, o variante +
  #    composición de una caja personalizable, ver Retail::BoxComposition) y cantidades. Cada variante tiene que estar habilitada, su producto seguir publicado
  #    (RetailProduct.for_store) y el precio sale de la variante vigente; precios, descuentos o totales
  #    del navegador no existen para este servicio;
  #  - stock online: si la variante tiene stock limitado, el pedido lo reserva al crearse (también
  #    pendiente de confirmación) con la variante bloqueada (Retail::OnlineStock): no se vende más de
  #    lo cargado aunque lleguen compras simultáneas;
  #  - entrega: modalidad, fecha (anticipación en días calendario de Argentina, días habilitados,
  #    fechas sin servicio), zona activa y dirección, con RetailFulfillment::Quote; el envío sale de
  #    la zona.
  # Después delega en Retail::SaveOrder con source "store": nace "Pendiente de confirmación" y no
  # cuenta para producción ni stock hasta que el equipo lo confirma.
  # El mismo request_token devuelve el pedido ya creado (doble toque, recarga, volver atrás).
  #
  # Cada producto de la tienda vinculado a un producto mayorista activo entra como ese producto
  # (producción y stock al confirmarse, igual que un pedido manual); sin vínculo entra como producto
  # especial. En los dos casos el ítem guarda el nombre de la tienda y el precio minorista.
  class PlaceStoreOrder
    # Lo único que se toma del cliente. Nada de envío, total, precios ni nombre de zona.
    CUSTOMER_FIELDS = %i[buyer_name buyer_phone buyer_email delivery_kind delivery_date delivery_zone_id address notes planned_payment_method].freeze
    PAYMENT_METHODS = RetailOrder::STORE_PAYMENT_METHOD_LABELS.keys.freeze
    MAX_QUANTITY = 99
    MAX_LINES = 30
    MAX_NOTES = 1000

    def self.call(**args)
      new(**args).call
    end

    # cart: { clave de línea => cantidad } (lo que guarda Retail::StoreCart).
    def self.preview(**args)
      new(request_token: nil, **args).preview
    end

    def initialize(attributes:, cart:, request_token:, now: Time.current)
      @attributes = attributes.to_h.with_indifferent_access.slice(*CUSTOMER_FIELDS)
      @cart = cart.to_h
      @request_token = request_token
      @now = now
    end

    def call
      token = @request_token.to_s.strip.presence
      return Result.new(record: RetailOrder.new, errors: ["No se pudo identificar el envío del pedido. Recargá la página y probá de nuevo."]) unless token
      if (existing = RetailOrder.find_by(request_token: token))
        return Result.new(record: existing, errors: [], duplicate: true)
      end

      errors, items, quote = validate
      return Result.new(record: RetailOrder.new, errors: errors) if errors.any?

      SaveOrder.call(order: RetailOrder.new, attributes: order_attributes(quote), items: items, user: nil, source: "store",
        request_token: token, fulfillment: quote)
    end

    # Vista previa (tienda cerrada, administrador): las mismas validaciones y cálculos, pero el pedido
    # se arma EN MEMORIA, sin escribir nada en la base (ni siquiera consume un número de pedido).
    def preview
      errors, items, quote = validate
      return Result.new(record: RetailOrder.new, errors: errors) if errors.any?

      attributes = order_attributes(quote)
      order = RetailOrder.new(
        attributes.slice(:buyer_name, :buyer_phone, :buyer_email, :delivery_kind, :address, :notes, :planned_payment_method)
          .merge(delivery_date: quote.date, delivery_zone: quote.zone, delivery_zone_name: quote.zone_name,
                 delivery_window_label: quote.window_label, shipping_cents: quote.shipping_cents,
                 subtotal_cents: quote.subtotal_cents, total_cents: quote.total_cents, source: "store", confirmation_status: "awaiting")
      )
      items.each do |item|
        order.retail_order_items.build(product_id: item["product_id"].presence, description: item["description"], retail_product_id: item["retail_product_id"],
          retail_product_variant_id: item["retail_product_variant_id"], variant_name_snapshot: item["variant_name"],
          product_name_snapshot: item["name"], quantity: item["quantity"], unit_price_cents: item["unit_price_cents"],
          line_total_cents: item["quantity"] * item["unit_price_cents"], composition: item["composition"])
      end
      Result.new(record: order, errors: [])
    end

    private

    def validate
      errors = buyer_errors
      items = build_items(errors)
      subtotal = items.sum { |item| item["quantity"] * item["unit_price_cents"] }
      quote = RetailFulfillment::Quote.call(service: @attributes[:delivery_kind], date: @attributes[:delivery_date],
        zone_id: @attributes[:delivery_zone_id], address: @attributes[:address], subtotal_cents: subtotal, now: @now)
      errors.concat(quote.errors)
      [errors.uniq, items, quote]
    end

    def order_attributes(quote)
      @attributes.except(:delivery_zone_id).merge(delivery_kind: quote.service, delivery_date: quote.date.iso8601,
        address: quote.address, delivery_time_note: nil, shipping: "", notes: @attributes[:notes].to_s.strip.presence)
    end

    def buyer_errors
      errors = []
      name = @attributes[:buyer_name].to_s.squish
      errors << "Completá tu nombre y apellido." if name.empty?
      errors << "El nombre es demasiado largo." if name.length > 150

      digits = @attributes[:buyer_phone].to_s.gsub(/\D/, "")
      if digits.empty?
        errors << "Completá tu celular con WhatsApp."
      elsif digits.length < 8 || digits.length > 15 || @attributes[:buyer_phone].to_s.length > 40
        errors << "Revisá el celular: escribilo con código de área, por ejemplo 223 5275412."
      end

      email = @attributes[:buyer_email].to_s.strip
      if email.empty?
        errors << "Completá tu email."
      elsif email.length > 150 || !email.match?(URI::MailTo::EMAIL_REGEXP)
        errors << "Revisá el email: no parece válido."
      end

      method = @attributes[:planned_payment_method].to_s
      errors << "Elegí la forma de pago: transferencia bancaria o efectivo." unless PAYMENT_METHODS.include?(method)
      errors << "Las notas del pedido pueden tener hasta #{MAX_NOTES} caracteres." if @attributes[:notes].to_s.strip.length > MAX_NOTES
      errors
    end

    # Ítems con precio del catálogo minorista vigente. Del carrito solo se usan claves de línea
    # (variante o variante + composición, ver Retail::BoxComposition) y cantidades.
    def build_items(errors)
      errors_before = errors.size
      wanted = {}
      @cart.each do |key, quantity|
        key = key.to_s
        quantity = quantity.to_s
        next errors << "Uno de los productos del carrito no es válido." unless BoxComposition.valid_key?(key)
        unless quantity.match?(/\A\d{1,3}\z/) && quantity.to_i.between?(1, MAX_QUANTITY)
          next errors << "Las cantidades tienen que ser de 1 a #{MAX_QUANTITY} por producto."
        end

        wanted[key] = quantity.to_i
      end
      if wanted.empty?
        errors << "Tu carrito está vacío." if errors.empty?
        return []
      end
      if wanted.size > MAX_LINES
        errors << "El carrito puede tener hasta #{MAX_LINES} productos distintos."
        return []
      end

      parsed = wanted.keys.index_with { |key| BoxComposition.parse_key(key) }
      variants = RetailProductVariant.active.includes(:product, retail_product: [:product, :flavors])
                                     .where(id: parsed.values.map(&:first).uniq, retail_product_id: RetailProduct.for_store.select(:id)).index_by(&:id)
      missing = parsed.values.map(&:first).uniq - variants.keys
      errors << "Algunos productos del carrito ya no están disponibles. Revisá el carrito." if missing.any?

      # Aviso temprano de stock limitado, sumando todas las líneas de la misma variante (cajas con
      # distinta composición comparten el stock de su presentación). La reserva definitiva, con la
      # variante bloqueada, la hace Retail::OnlineStock.
      per_variant = Hash.new(0)
      wanted.each { |key, quantity| per_variant[parsed[key].first] += quantity }
      per_variant.each do |variant_id, total|
        variant = variants[variant_id]
        next unless variant&.limited_stock? && variant.stock_quantity < total

        errors << Retail::OnlineStock::Insufficient.new(variant, variant.stock_quantity, total).message
      end
      return [] if errors.size > errors_before

      wanted.filter_map do |key, quantity|
        variant_id, quantities = parsed[key]
        variant = variants[variant_id]
        next unless variant

        composition = composition_for(variant, quantities, errors)
        next if composition == false

        wholesale = variant.wholesale_product if variant.wholesale_product&.active?
        {
          "kind" => wholesale ? "product" : "manual",
          "product_id" => wholesale&.id.to_s,
          "description" => wholesale ? nil : variant.full_name,
          "quantity" => quantity,
          "unit_price_cents" => variant.price_cents,
          "retail_product_id" => variant.retail_product_id,
          "retail_product_variant_id" => variant.id,
          "variant_name" => variant.name,
          "name" => variant.full_name,
          "composition" => composition
        }
      end
    end

    # Caja con contenido personalizable: la composición se valida de nuevo acá (sabores del producto,
    # habilitados y suma exacta). Devuelve el snapshot, nil (producto común) o false (error).
    def composition_for(variant, quantities, errors)
      unless variant.customizable?
        return nil if quantities.nil?

        errors << "“#{variant.full_name}” ya no permite elegir sabores: quitalo del carrito y agregalo de nuevo."
        return false
      end
      if quantities.nil?
        errors << "Elegí los sabores de “#{variant.full_name}” en el carrito antes de finalizar."
        return false
      end

      result = BoxComposition.validate(variant: variant, quantities: quantities)
      return result.snapshot if result.ok?

      errors << "#{result.errors.first} Corregila en el carrito."
      false
    end
  end
end
