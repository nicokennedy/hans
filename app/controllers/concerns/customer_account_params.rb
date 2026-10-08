# Lectura de los formularios de cuenta corriente: importes en pesos -> centavos enteros
# y distribución { order_id => centavos }. Todo lo inválido se informa; nada se adivina.
module CustomerAccountParams
  extend ActiveSupport::Concern

  private

  # Devuelve [ { order_id => cents }, errores ]
  def parse_allocations(raw)
    allocations = {}
    errors = []
    return [allocations, errors] unless raw.respond_to?(:each_pair)

    raw.each_pair do |order_id, text|
      next if text.to_s.strip.empty?

      cents = CustomerAccounts::Money.parse_pesos(text)
      id = Integer(order_id.to_s, exception: false)

      if cents.nil? || id.nil?
        errors << "El importe «#{text.to_s.truncate(20)}» no es válido."
      else
        allocations[id] = cents
      end
    end

    [allocations, errors]
  end

  def parse_paid_on(text)
    return Date.current if text.blank?

    Date.iso8601(text.to_s)
  rescue ArgumentError
    nil
  end
end
