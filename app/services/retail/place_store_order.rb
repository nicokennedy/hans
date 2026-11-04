module Retail
  # Alta de un pedido de la TIENDA ONLINE (lo que llamará el checkout de la Etapa 4). Aplica las
  # reglas de entrega minoristas en el servidor antes de crear nada:
  #  - modalidad, fecha (anticipación mínima en días calendario de Argentina, días habilitados y
  #    fechas excepcionales), zona activa y dirección, con RetailFulfillment::Quote;
  #  - el costo de envío sale de la zona: los parámetros del cliente no traen importes de envío
  #    (si los traen, se ignoran).
  # Después delega en Retail::SaveOrder con source "store": nace "Pendiente de confirmación".
  # El mismo request_token devuelve el pedido ya creado, aunque su fecha ya no sea elegible.
  class PlaceStoreOrder
    # Lo único que se toma del cliente. Nada de shipping / total / zona por nombre.
    CUSTOMER_FIELDS = %i[buyer_name buyer_phone delivery_kind delivery_date delivery_zone_id address notes planned_payment_method].freeze

    def self.call(**args)
      new(**args).call
    end

    def initialize(attributes:, items:, request_token:, now: Time.current)
      @attributes = attributes.to_h.with_indifferent_access.slice(*CUSTOMER_FIELDS)
      @items = items
      @request_token = request_token
      @now = now
    end

    def call
      token = @request_token.to_s.strip.presence
      if token && (existing = RetailOrder.find_by(request_token: token))
        return Result.new(record: existing, errors: [], duplicate: true)
      end

      quote = RetailFulfillment::Quote.call(service: @attributes[:delivery_kind], date: @attributes[:delivery_date],
        zone_id: @attributes[:delivery_zone_id], address: @attributes[:address], now: @now)
      return Result.new(record: RetailOrder.new, errors: quote.errors) unless quote.ok?

      attributes = @attributes.except(:delivery_zone_id).merge(delivery_kind: quote.service, delivery_date: quote.date.iso8601,
        address: quote.address, delivery_time_note: nil, shipping: "")
      SaveOrder.call(order: RetailOrder.new, attributes: attributes, items: @items, user: nil, source: "store",
        request_token: @request_token, fulfillment: quote)
    end
  end
end
