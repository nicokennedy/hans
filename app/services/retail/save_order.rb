module Retail
  # Crea o edita un pedido minorista con todos sus ítems en UNA transacción (con el pedido
  # bloqueado al editar). Valida todo del lado del servidor (la UI solo ayuda):
  #  - comprador, fecha de entrega (cualquier día), tipo de entrega y medio de pago previsto;
  #  - ítems de catálogo (producto + cantidad + precio manual) o manuales (descripción + cantidad
  #    + precio manual), cantidad entera > 0, precio >= 0, centavos enteros;
  #  - subtotal = suma de líneas; total = subtotal + envío (recalculado acá, nunca confiado al cliente).
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
  class SaveOrder
    def self.call(**args)
      new(**args).call
    end

    # attributes: Hash con buyer_name, buyer_phone, delivery_date (texto ISO), delivery_kind,
    #   delivery_time_note, address, notes, planned_payment_method, shipping (texto en pesos).
    # items: [{ "id", "kind" ("product"|"manual"), "product_id", "description", "quantity", "unit_price" }]
    SOURCES = RetailOrder.sources.keys.freeze

    def initialize(order:, attributes:, items:, user:, source: "manual", request_token: nil)
      @order = order
      @attributes = attributes.to_h.with_indifferent_access
      @rows = Array(items).map { |row| row.to_h.with_indifferent_access }
      @user = user
      @source = source.to_s
      @request_token = request_token.to_s.strip.presence
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

        order.assign_attributes(attrs.merge(subtotal_cents: subtotal, total_cents: total))
        assign_origin(order) if creating
        order.created_by ||= @user if creating
        order.save!

        sync_items(order, parsed_items)
        order.retail_order_items.reset
        order.recalculate_payment_state!

        log_creation(order) if creating
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
      shipping = parse_shipping(errors)
      kind = @attributes[:delivery_kind].presence || "pickup"
      errors << "El tipo de entrega no es válido." unless RetailOrder.delivery_kinds.key?(kind)
      planned = @attributes[:planned_payment_method].presence
      errors << "El medio de pago previsto no es válido." if planned && !RetailOrder::PAYMENT_METHODS.include?(planned)
      errors << "El nombre y apellido del comprador es obligatorio." if @attributes[:buyer_name].to_s.strip.empty?

      {
        buyer_name: @attributes[:buyer_name],
        buyer_phone: @attributes[:buyer_phone],
        delivery_date: date,
        delivery_kind: kind,
        delivery_time_note: @attributes[:delivery_time_note],
        address: @attributes[:address],
        notes: @attributes[:notes],
        planned_payment_method: planned,
        shipping_cents: shipping
      }
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
      %w[product_id description quantity unit_price].all? { |key| row[key].to_s.strip.empty? }
    end

    def parse_items(errors)
      @rows.reject { |row| blank_row?(row) }.each_with_index.filter_map do |row, index|
        label = "Ítem #{index + 1}"
        row_errors = []
        manual = row[:kind].to_s == "manual"
        product = nil

        if manual
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

        price = row[:unit_price].to_s.strip.empty? ? nil : Money.parse_pesos(row[:unit_price])
        row_errors << "#{label}: el precio unitario es obligatorio y debe ser un importe válido (puede ser 0)." if price.nil?
        row_errors << "#{label}: el importe de la línea es demasiado alto." if price && quantity && price * quantity > RetailOrder::MAX_CENTS

        errors.concat(row_errors)
        next if row_errors.any?

        { id: row[:id].to_s.match?(/\A\d{1,18}\z/) ? row[:id].to_i : nil, product: product,
          description: manual ? row[:description].to_s.squish : nil, quantity: quantity, unit_price_cents: price }
      end
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
