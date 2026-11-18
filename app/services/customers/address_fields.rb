module Customers
  # Campos de dirección de entrega de un cliente mayorista: un solo lugar para el Excel de
  # direcciones (Customers::AddressExport) y su importación por consola
  # (Customers::AddressImport). Solo estos campos se pueden actualizar desde el Excel.
  #
  # Hoy la tabla customers solo tiene `address` (texto libre). El resto de los campos está
  # PROPUESTO (ver docs/CLIENTES_DIRECCIONES.md): se exportan vacíos para que HANS los
  # complete, y la importación no los escribe hasta que exista la columna (stored? == false).
  module AddressFields
    Field = Struct.new(:column, :header, :width, :max_length, keyword_init: true) do
      def stored?
        Customer.column_names.include?(column)
      end
    end

    ALL = [
      Field.new(column: "address", header: "Dirección (calle y número)", width: 38, max_length: 150),
      Field.new(column: "address_unit", header: "Piso / depto / local", width: 18, max_length: 40),
      Field.new(column: "city", header: "Localidad", width: 22, max_length: 80),
      Field.new(column: "province", header: "Provincia", width: 22, max_length: 60),
      Field.new(column: "postal_code", header: "Código postal", width: 14, max_length: 8),
      Field.new(column: "delivery_instructions", header: "Referencias de entrega", width: 46, max_length: 500)
    ].freeze

    PROVINCES = [
      "Buenos Aires", "Ciudad Autónoma de Buenos Aires", "Catamarca", "Chaco", "Chubut", "Córdoba",
      "Corrientes", "Entre Ríos", "Formosa", "Jujuy", "La Pampa", "La Rioja", "Mendoza", "Misiones",
      "Neuquén", "Río Negro", "Salta", "San Juan", "San Luis", "Santa Cruz", "Santa Fe",
      "Santiago del Estero", "Tierra del Fuego", "Tucumán"
    ].freeze
    PROVINCE_ALIASES = {
      "caba" => "Ciudad Autónoma de Buenos Aires", "capital federal" => "Ciudad Autónoma de Buenos Aires",
      "ciudad de buenos aires" => "Ciudad Autónoma de Buenos Aires", "bs as" => "Buenos Aires",
      "bs. as." => "Buenos Aires", "pba" => "Buenos Aires", "provincia de buenos aires" => "Buenos Aires",
      "tierra del fuego, antartida e islas del atlantico sur" => "Tierra del Fuego"
    }.freeze

    module_function

    def stored
      ALL.select(&:stored?)
    end

    def pending
      ALL.reject(&:stored?)
    end

    def fold(text)
      I18n.transliterate(text.to_s.unicode_normalize(:nfc)).downcase.squish
    end

    # Devuelve [valor_normalizado, nil] o [nil, "motivo"] para un valor NO vacío de la planilla.
    def normalize(field, raw)
      value = raw.to_s.gsub(/[\r\n\t]+/, " ").squish
      return [nil, "empieza con \"=\" (parece una fórmula)"] if value.start_with?("=", "+", "@")
      return [nil, "es demasiado largo (máximo #{field.max_length} caracteres)"] if value.length > field.max_length

      case field.column
      when "address"
        return [nil, "es demasiado corta"] if value.length < 4
        return [nil, "no tiene letras"] unless value.match?(/\p{L}/)
        return [nil, "no tiene número (si no tiene, escribí S/N)"] unless value.match?(/\d/) || value.match?(%r{\bs/?n\b}i)
      when "city"
        return [nil, "no tiene letras"] unless value.match?(/\p{L}/)
      when "province"
        canonical = PROVINCES.find { |name| fold(name) == fold(value) } || PROVINCE_ALIASES[fold(value)]
        return [nil, "no es una provincia argentina reconocida"] unless canonical

        value = canonical
      when "postal_code"
        value = value.delete(" ").upcase
        value = value.delete_suffix(".0") if value.match?(/\A\d{4}\.0\z/)
        return [nil, "no es un código postal válido (4 números, ej. 7600, o CPA, ej. B7600ABC)"] unless value.match?(/\A(\d{4}|[A-Z]\d{4}[A-Z]{3})\z/)
      end

      [value, nil]
    end
  end
end
