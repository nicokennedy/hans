# Lectura de formularios del módulo de Administración: importes en pesos -> centavos
# enteros, cantidades decimales exactas y fechas ISO. Todo lo inválido se informa; nada se adivina.
module FinanceParams
  extend ActiveSupport::Concern

  private

  # Devuelve [centavos, error?]. Vacío -> blank (por defecto nil). Admite signo "-" si signed.
  def money_param(text, label, blank: nil, signed: false)
    value = text.to_s.strip
    return [blank, nil] if value.empty?

    negative = signed && value.start_with?("-")
    cents = Finance::Money.parse_pesos(negative ? value.delete_prefix("-") : value)
    return [nil, "#{label} no es un importe válido."] if cents.nil?

    [negative ? -cents : cents, nil]
  end

  def date_param(text, label, required: false)
    return [nil, (required ? "#{label} es obligatoria." : nil)] if text.blank?

    [Date.iso8601(text.to_s), nil]
  rescue ArgumentError
    [nil, "#{label} no es una fecha válida."]
  end

  def hash_values(raw)
    return raw.map { |row| row.respond_to?(:to_unsafe_h) ? row.to_unsafe_h : row.to_h } if raw.is_a?(Array)
    return [] unless raw.respond_to?(:to_unsafe_h)

    raw.to_unsafe_h.sort_by { |key, _| key.to_s.to_i }.map(&:last)
  end

  # Ítems de compra: [[{id:, description:, quantity:, unit:, unit_price_cents:}], errores, filas_crudas]
  def parse_purchase_items(raw)
    rows = hash_values(raw).select { |row| %w[description quantity unit_price].any? { |key| row[key].to_s.strip.present? } }
    errors = []

    items = rows.each_with_index.map do |row, index|
      quantity = Finance::Money.parse_quantity(row["quantity"])
      price, price_error = money_param(row["unit_price"], "El precio", blank: nil)
      errors << "Ítem #{index + 1}: la cantidad no es válida (usá, por ejemplo, 2,5; un valor como 1.250 es ambiguo)." if quantity.nil?
      errors << "Ítem #{index + 1}: #{price_error}" if price_error
      errors << "Ítem #{index + 1}: falta el precio unitario." if price.nil? && price_error.nil?
      { id: row["id"].presence, description: row["description"].to_s.strip, quantity: quantity, unit: row["unit"].to_s, unit_price_cents: price }
    end

    [items.reject { |item| item[:quantity].nil? || item[:unit_price_cents].nil? }, errors, rows]
  end

  def parse_pay_now(prefix = :pay_now)
    return [nil, []] unless params[prefix].to_s == "1"

    amount, amount_error = money_param(params[:pay_amount], "El importe del pago", blank: nil)
    paid_on, date_error = date_param(params[:pay_paid_on], "La fecha del pago")
    errors = [amount_error, date_error].compact
    errors << "Indicá el importe del pago." if amount.nil? && amount_error.nil?

    [{ amount_cents: amount, paid_on: paid_on, payment_method: params[:pay_method], reference: params[:pay_reference], request_token: params[:request_token] }, errors]
  end
end
