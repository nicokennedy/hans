module RetailFulfillment
  # Valida la elección de entrega de un cliente y calcula envío y total, todo en el servidor:
  #  - modalidad "pickup" (Retiro por zona Plaza del Agua, gratis) o "delivery" (Envío a domicilio);
  #  - fecha habilitada según RetailFulfillment::Calendar (anticipación, días, excepciones);
  #  - para envío: zona existente y activa, y dirección; el costo sale SIEMPRE de la zona (no se
  #    recibe ningún importe del cliente, así que no se puede manipular).
  # Es lo que usará el checkout de la tienda pública y lo que aplica Retail::SaveOrder a los pedidos
  # que llegan de la tienda (source "store").
  class Quote
    Result = Struct.new(:service, :service_name, :date, :window_label, :zone, :address, :shipping_cents,
      :subtotal_cents, :total_cents, :errors, keyword_init: true) do
      def ok?
        errors.empty?
      end

      def zone_name
        zone&.name
      end
    end

    def self.call(**args)
      new(**args).call
    end

    # service: "pickup" | "delivery"; date: Date o texto ISO (AAAA-MM-DD); zone_id: id de
    # RetailDeliveryZone (solo envío); address: texto (solo envío); subtotal_cents: entero >= 0.
    def initialize(service:, date:, zone_id: nil, address: nil, subtotal_cents: 0, now: Time.current, calendar: nil)
      @service = service.to_s
      @date_input = date
      @zone_id = zone_id
      @address = address.to_s.squish.presence
      @subtotal_cents = subtotal_cents
      @calendar = calendar || Calendar.new(now: now)
    end

    def call
      errors = []
      unless @subtotal_cents.is_a?(Integer) && @subtotal_cents >= 0
        errors << "El subtotal de los productos no es válido."
        @subtotal_cents = 0
      end

      date = parse_date(errors)
      unless @invalid_date
        reason = @calendar.unavailable_reason(@service, date)
        errors << reason if reason
      end

      zone = nil
      shipping = 0
      address = nil
      if @service == "delivery"
        zone = find_zone(errors)
        shipping = zone.price_cents if zone
        address = @address
        if address.nil?
          errors << "Completá la dirección de entrega."
        elsif address.length > 250
          errors << "La dirección es demasiado larga."
        end
      end

      Result.new(
        service: @service, service_name: RetailFulfillment.service_name(@service), date: date,
        window_label: (date && RetailServiceWindow::SERVICES.include?(@service) ? @calendar.window_label(@service, date) : nil),
        zone: zone, address: address, shipping_cents: shipping, subtotal_cents: @subtotal_cents,
        total_cents: @subtotal_cents + shipping, errors: errors.uniq
      )
    end

    private

    def parse_date(errors)
      return @date_input if @date_input.is_a?(Date)
      return nil if @date_input.blank? # el Calendar avisa "Elegí una fecha de entrega."

      Date.iso8601(@date_input.to_s)
    rescue ArgumentError
      @invalid_date = true
      errors << "La fecha de entrega no es válida."
      nil
    end

    def find_zone(errors)
      text = @zone_id.to_s.strip
      if text.empty?
        errors << "Elegí la zona de envío."
        return nil
      end

      zone = text.match?(/\A\d{1,18}\z/) ? RetailDeliveryZone.find_by(id: text.to_i) : nil
      if zone.nil? || !zone.active?
        errors << "La zona de envío elegida no está disponible."
        return nil
      end
      zone
    end
  end
end
