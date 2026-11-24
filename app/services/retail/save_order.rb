module Retail
  # Crea o edita un pedido minorista con todos sus ítems en UNA transacción (con el pedido
  # bloqueado al editar). Valida todo del lado del servidor (la UI solo ayuda):
  #  - comprador, fecha de entrega (cualquier día), tipo de entrega y medio de pago previsto;
  #  - ítems de catálogo (producto + cantidad + precio manual) o manuales (descripción + cantidad
  #    + precio manual), cantidad entera > 0, precio >= 0, centavos enteros;
  #  - subtotal = suma de líneas; total = subtotal + envío (recalculado acá, nunca confiado al cliente).
  # Stock de venta online (solo ítems de la tienda con variante): Retail::OnlineStock descuenta o
  # devuelve la diferencia contra lo ya reservado; si no alcanza, no se guarda nada.
  # Al guardar concilia stock con el mismo mecanismo que los pedidos mayoristas
  # (Stock::DispatchReconciler): alta, cambio de cantidades o de fecha mueven la demanda por
  # diferencia, sin duplicar movimientos. Si el nuevo total queda por debajo de lo pagado, los
  # pagos se conservan y el saldo queda como excedente (ver RetailOrder#excess_cents).
  #
  # Origen y confirmación (solo al crear): source "manual" (el equipo, por defecto) nace
  # confirmado, con fecha y usuario; source "store" (la futura tienda online) nace pendiente de
  # confirmación y no cuenta para producción ni stock. request_token hace idempotente el alta:
  # el mismo token devuelve el pedido ya creado (duplicate: true), también ante dos envíos
  # simultáneos (índice único). Al editar, origen y confirmación no cambian.
  #
  # Entrega (Etapa 3): el equipo puede elegir una zona de envío (delivery_zone_id) para registrar
  # el pedido; si deja el envío vacío se usa el precio de esa zona, pero puede escribir otro
  # importe (pedidos especiales) y cualquier fecha. La zona, su nombre y la franja quedan copiados
  # en el pedido. Los pedidos de la TIENDA no entran por acá con datos del cliente: los crea
  # Retail::PlaceStoreOrder, que valida fecha, zona y dirección con RetailFulfillment::Quote y pasa
  # el resultado en fulfillment: (el envío sale de la zona, nunca de un importe del cliente).
  class SaveOrder
    def self.call(**args)
      new(**args).call
    end

    # attributes: Hash con buyer_name, buyer_phone, buyer_email, delivery_date (texto ISO), delivery_kind,
    #   delivery_time_note, address, notes, planned_payment_method, shipping (texto en pesos).
    # items: [{ "id", "kind" ("product"|"manual"|"box"), "product_id", "description", "quantity", "unit_price" }]
    #   "box" (Etapa 2): una caja con contenido personalizable cargada o editada por el equipo, con
    #   "retail_product_variant_id" y "composition" ({ "id de sabor" => cantidad }). Se valida igual que
    #   en la tienda (Retail::BoxComposition: sabores del producto y suma exacta). El equipo puede
    #   conservar en un pedido un sabor que se deshabilitó después, pero no agregar uno deshabilitado.
    #   Cada cambio de composición queda en el historial del pedido.
    #   Los ítems de la TIENDA los arma Retail::PlaceStoreOrder en el servidor desde el catálogo
    #   minorista (nunca desde el navegador) y traen además "retail_product_id", "name" (nombre del
    #   producto de la tienda) y "unit_price_cents" (precio vigente del catálogo); solo se aceptan
    #   en ese camino (con fulfillment:).
    SOURCES = RetailOrder.sources.keys.freeze

    def initialize(order:, attributes:, items:, user:, source: "manual", request_token: nil, fulfillment: nil)
      @order = order
      @attributes = attributes.to_h.with_indifferent_access
      @rows = Array(items).map { |row| row.to_h.with_indifferent_access }
      @user = user
      @source = source.to_s
      @request_token = request_token.to_s.strip.presence
      @fulfillment = fulfillment
    end

    def call
      return failure(["El origen del pedido no es válido."]) unless SOURCES.include?(@source)
      return failure(["El token del pedido no es válido."]) if @request_token && @request_token.length > 100

      if @order.new_record? && (existing = existing_for_token)
        return Result.new(record: existing, errors: [], duplicate: true)
      end

      errors = []
      attrs = parse_attributes(errors)
      parsed_items = parse_items(errors)
      errors << "El pedido debe tener al menos un producto." if parsed_items.empty? && errors.none? { |e| e.start_with?("Ítem") }
      return failure(errors) if errors.any?

      subtotal = parsed_items.sum { |item| item[:quantity] * item[:unit_price_cents] }
      total = subtotal + attrs[:shipping_cents]
      return failure(["El total supera el máximo permitido."]) if total > RetailOrder::MAX_CENTS || attrs[:shipping_cents] > RetailOrder::MAX_CENTS

      saved = nil
      ActiveRecord::Base.transaction(requires_new: true) do
        order = @order.persisted? ? RetailOrder.lock.find(@order.id) : @order
        @order = order
        creating = order.new_record?

        attrs[:delivery_window_label] = window_label_for(order, attrs)
        order.assign_attributes(attrs.merge(subtotal_cents: subtotal, total_cents: total))
        assign_origin(order) if creating
        order.created_by ||= @user if creating
        order.save!

        previous_boxes = creating ? {} : box_snapshots(order)
        sync_items(order, parsed_items)
        order.retail_order_items.reset
        log_box_changes(order, previous_boxes) unless creating
        order.recalculate_payment_state!

        log_creation(order) if creating
        OnlineStock.reconcile!(order)
        Stock::DispatchReconciler.call(order)
        saved = order
      end

      Result.new(record: saved, errors: [])
    rescue ActiveRecord::RecordNotUnique
      # Otro envío con el mismo token ganó la carrera: se devuelve ese pedido, nunca un segundo.
      existing = existing_for_token
      existing ? Result.new(record: existing, errors: [], duplicate: true) : failure(["No se pudo guardar el pedido. Probá de nuevo."])
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages)
    rescue OnlineStock::Insufficient => e
      failure([e.message])
    end

    private

    def existing_for_token
      @request_token && RetailOrder.find_by(request_token: @request_token)
    end

    def assign_origin(order)
      order.source = @source
      order.request_token = @request_token
      if order.source_store?
        order.confirmation_status = "awaiting"
      else
        order.confirmation_status = "confirmed"
        order.confirmed_at = Time.current
        order.confirmed_by = @user
      end
    end

    def failure(errors)
      Result.new(record: @order, errors: errors)
    end

    def parse_attributes(errors)
      date = parse_date(@attributes[:delivery_date], errors)
      kind = @attributes[:delivery_kind].presence || "pickup"
      errors << "El tipo de entrega no es válido." unless RetailOrder.delivery_kinds.key?(kind)
      zone = zone_attributes(kind, errors)
      shipping = if @fulfillment
                   @fulfillment.shipping_cents
                 elsif @attributes[:shipping].to_s.strip.empty? && zone[:delivery_zone]
                   zone[:delivery_zone].price_cents # zona recién elegida y envío vacío: el precio de la zona
                 else
                   parse_shipping(errors)
                 end
      planned = @attributes[:planned_payment_method].presence
      errors << "El medio de pago previsto no es válido." if planned && !RetailOrder::PAYMENT_METHODS.include?(planned)
      errors << "El nombre y apellido del comprador es obligatorio." if @attributes[:buyer_name].to_s.strip.empty?

      {
        buyer_name: @attributes[:buyer_name],
        buyer_phone: @attributes[:buyer_phone],
        buyer_email: @attributes[:buyer_email],
        delivery_date: date,
        delivery_kind: kind,
        delivery_time_note: @attributes[:delivery_time_note],
        address: @attributes[:address],
        notes: @attributes[:notes],
        planned_payment_method: planned,
        shipping_cents: shipping
      }.merge(zone)
    end

    # Zona de envío. Sin envío a domicilio no hay zona. Si el pedido ya tenía esa zona, se conserva
    # el nombre guardado (histórico) aunque la zona se haya renombrado o desactivado después.
    def zone_attributes(kind, errors)
      if @fulfillment
        return { delivery_zone: @fulfillment.zone, delivery_zone_name: @fulfillment.zone_name, address: @fulfillment.address }
      end
      return { delivery_zone: nil, delivery_zone_name: nil } unless kind == "delivery"
      return {} unless @attributes.key?(:delivery_zone_id) # quien no manda zona no la cambia

      text = @attributes[:delivery_zone_id].to_s.strip
      return { delivery_zone: nil, delivery_zone_name: nil } if text.empty?

      zone = text.match?(/\A\d{1,18}\z/) ? RetailDeliveryZone.find_by(id: text.to_i) : nil
      if zone.nil?
        errors << "La zona de envío elegida no existe."
        return {}
      end
      return {} if zone.id == @order.delivery_zone_id

      errors << "La zona de envío \"#{zone.name}\" está desactivada." unless zone.active?
      { delivery_zone: zone, delivery_zone_name: zone.name }
    end

    # Franja guardada en el pedido: la que validó la tienda. Si el equipo cambia la fecha o la
    # modalidad de un pedido que tenía franja, se toma la del nuevo día (o ninguna).
    def window_label_for(order, attrs)
      return @fulfillment.window_label if @fulfillment
      return order.delivery_window_label if order.delivery_window_label.blank?
      return order.delivery_window_label if order.delivery_date == attrs[:delivery_date] && order.delivery_kind == attrs[:delivery_kind]

      RetailFulfillment::Calendar.new.window_label(attrs[:delivery_kind], attrs[:delivery_date])
    end

    def parse_date(value, errors)
      if value.blank?
        errors << "La fecha de entrega es obligatoria."
        return nil
      end
      return value if value.is_a?(Date)

      Date.iso8601(value.to_s)
    rescue ArgumentError
      errors << "La fecha de entrega no es válida."
      nil
    end

    def parse_shipping(errors)
      text = @attributes[:shipping].to_s.strip
      return 0 if text.empty?

      cents = Money.parse_pesos(text)
      errors << "El envío no es un importe válido." if cents.nil?
      cents || 0
    end

    def current_product_ids
      @current_product_ids ||= @order.persisted? ? @order.retail_order_items.pluck(:product_id).compact : []
    end

    def blank_row?(row)
      %w[product_id description quantity unit_price retail_product_variant_id].all? { |key| row[key].to_s.strip.empty? }
    end

    def parse_items(errors)
      @rows.reject { |row| blank_row?(row) }.each_with_index.filter_map do |row, index|
        label = "Ítem #{index + 1}"
        row_errors = []
        manual = row[:kind].to_s == "manual"
        box = row[:kind].to_s == "box" && !store_row?(row)
        product = nil
        box_data = nil

        if box
          box_data = parse_box(row, label, row_errors)
          product = box_data&.dig(:product)
        elsif manual
          row_errors << "#{label}: la descripción del producto manual es obligatoria." if row[:description].to_s.strip.empty?
          row_errors << "#{label}: la descripción es demasiado larga." if row[:description].to_s.squish.length > 200
        else
          product = row[:product_id].to_s.match?(/\A\d{1,18}\z/) ? Product.find_by(id: row[:product_id].to_i) : nil
          row_errors << "#{label}: elegí un producto." if product.nil?
          row_errors << "#{label}: el producto \"#{product.name}\" está inactivo." if product && !product.active? && !current_product_ids.include?(product.id)
        end

        quantity = row[:quantity].to_s.strip
        if quantity.match?(/\A\d{1,9}\z/) && quantity.to_i.positive? && quantity.to_i <= RetailOrderItem::MAX_QUANTITY
          quantity = quantity.to_i
        else
          row_errors << "#{label}: la cantidad debe ser un número entero mayor a cero."
          quantity = nil
        end

        price = if store_row?(row)
                  row[:unit_price_cents]
                else
                  row[:unit_price].to_s.strip.empty? ? nil : Money.parse_pesos(row[:unit_price])
                end
        row_errors << "#{label}: el precio unitario es obligatorio y debe ser un importe válido (puede ser 0)." if price.nil?
        row_errors << "#{label}: el importe de la línea es demasiado alto." if price && quantity && price * quantity > RetailOrder::MAX_CENTS

        errors.concat(row_errors)
        next if row_errors.any?

        if box_data
          next box_data.except(:product).merge(id: row_id(row), product: product, quantity: quantity, unit_price_cents: price)
        end

        { id: row_id(row), product: product,
          description: manual ? row[:description].to_s.squish : nil, quantity: quantity, unit_price_cents: price,
          retail_product_id: store_row?(row) ? row[:retail_product_id] : nil, name: store_row?(row) ? row[:name].to_s.squish.first(200) : nil,
          retail_product_variant_id: store_row?(row) ? row[:retail_product_variant_id] : nil, variant_name: store_row?(row) ? row[:variant_name].to_s.squish.first(60).presence : nil,
          composition: store_row?(row) && row[:composition].is_a?(Hash) ? row[:composition] : nil }
      end
    end

    # Ítem armado por Retail::PlaceStoreOrder desde el catálogo minorista (precio en centavos del
    # catálogo). Solo existe en el alta de la tienda: el formulario del equipo no puede usarlo.
    def store_row?(row)
      @fulfillment.present? && row[:retail_product_id].is_a?(Integer) && row[:unit_price_cents].is_a?(Integer)
    end

    def row_id(row)
      row[:id].to_s.match?(/\A\d{1,18}\z/) ? row[:id].to_i : nil
    end

    def existing_items
      @existing_items ||= @order.persisted? ? @order.retail_order_items.to_a.index_by(&:id) : {}
    end

    # Caja cargada por el equipo: variante de un producto con contenido personalizable + composición
    # validada con Retail::BoxComposition. Al cambiar de presentación la composición se valida contra
    # la nueva cantidad de unidades: si no coincide, se pide completarla de nuevo (nunca se borra sola).
    def parse_box(row, label, row_errors)
      text = row[:retail_product_variant_id].to_s
      variant = text.match?(/\A\d{1,18}\z/) ? RetailProductVariant.includes(:product, retail_product: [:product, :flavors]).find_by(id: text.to_i) : nil
      if variant.nil?
        row_errors << "#{label}: elegí la caja (producto y presentación)."
        return nil
      end

      current = existing_items[row_id(row)]
      unless variant.customizable?
        row_errors << "#{label}: “#{variant.full_name}” no permite elegir sabores."
        return nil
      end
      if !variant.active? && current&.retail_product_variant_id != variant.id
        row_errors << "#{label}: la presentación “#{variant.full_name}” está deshabilitada."
        return nil
      end

      quantities, errors = BoxComposition.quantities_from_params(row[:composition])
      if errors.any?
        row_errors << "#{label}: #{errors.first}"
        return nil
      end
      # Sabores que el pedido ya tenía (aunque hoy estén deshabilitados) se pueden conservar.
      allowed = current && current.retail_product_id == variant.retail_product_id ? BoxComposition.quantities_from_snapshot(current.composition).keys : []
      result = BoxComposition.validate(variant: variant, quantities: quantities, allowed_inactive_ids: allowed)
      unless result.ok?
        row_errors << "#{label}: #{result.errors.first}"
        return nil
      end

      wholesale = variant.wholesale_product if variant.wholesale_product&.active?
      { product: wholesale, description: wholesale ? nil : variant.full_name, box: true,
        retail_product_id: variant.retail_product_id, name: variant.full_name.first(200),
        retail_product_variant_id: variant.id, variant_name: variant.name, composition: result.snapshot }
    end

    # { id del ítem => [nombre, texto de la composición] } de las cajas del pedido antes de guardar.
    def box_snapshots(order)
      order.retail_order_items.reload.select(&:box?).to_h { |item| [item.id, [item.display_name, item.composition_text]] }
    end

    # Historial del pedido: cada caja agregada, quitada o con otra composición (antes → ahora).
    def log_box_changes(order, previous)
      current = box_snapshots(order)
      notes = []
      current.each do |id, (name, text)|
        before = previous[id]
        if before.nil?
          notes << "Caja agregada: #{name} (#{text})"
        elsif before != [name, text]
          notes << "Composición de #{before[0]}: antes #{before[1]}; ahora #{name == before[0] ? '' : "#{name}: "}#{text}"
        end
      end
      previous.each { |id, (name, text)| notes << "Caja quitada: #{name} (#{text})" unless current.key?(id) }
      return if notes.empty?

      RetailOrderStatusChange.create!(retail_order: order, from_status: order.status, to_status: order.status, user: @user, note: notes.join(" · "))
    end

    def sync_items(order, parsed_items)
      existing = order.persisted? ? order.retail_order_items.reload.index_by(&:id) : {}
      kept = []

      parsed_items.each_with_index do |data, position|
        item = existing[data[:id]] || order.retail_order_items.build
        previous_product_id = item.product_id
        item.product = data[:product]
        item.description = data[:description]
        # El snapshot del nombre se conserva mientras el ítem siga siendo el mismo producto.
        item.product_name_snapshot = nil if data[:product].nil? || previous_product_id != data[:product].id
        if data[:retail_product_id]
          item.retail_product_id = data[:retail_product_id]
          item.product_name_snapshot = data[:name] # el nombre que vio el cliente en la tienda
          item.retail_product_variant_id = data[:retail_product_variant_id]
          item.variant_name_snapshot = data[:variant_name]
          item.composition = data[:composition] if data[:composition] # caja personalizable: copia fija
        end
        item.quantity = data[:quantity]
        item.unit_price_cents = data[:unit_price_cents]
        item.position = position
        item.save!
        kept << item.id
      end

      existing.except(*kept).each_value(&:destroy!)
    end

    def log_creation(order)
      RetailOrderStatusChange.create!(retail_order: order, from_status: nil, to_status: order.status, user: @user, note: "Pedido creado")
    end
  end
end
