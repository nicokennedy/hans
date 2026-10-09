module Finance
  # Importes del módulo de Administración: centavos ENTEROS, nunca floats. Reutiliza el
  # parser de pesos de cuenta corriente de clientes y agrega cantidades decimales exactas.
  module Money
    module_function

    def parse_pesos(text)
      CustomerAccounts::Money.parse_pesos(text)
    end

    def format_pesos(cents)
      CustomerAccounts::Money.format_pesos(cents)
    end

    # "2,5" / "2.5" / "1.250,5" -> BigDecimal exacto (hasta 3 decimales); inválido -> nil.
    # No se adivina: "1.250" o "1,250" (un solo separador y 3 dígitos después, con parte
    # entera 1-3 dígitos distinta de 0) es ambiguo entre 1,25 y 1250, así que se rechaza;
    # hay que escribir "1250" o "1,25".
    def parse_quantity(text)
      value = text.to_s.gsub(/\s+/, "")
      return nil if value.empty? || value.match?(/[^\d.,]/)

      if value.include?(",") && value.include?(".")
        decimal_sep = value.rindex(",") > value.rindex(".") ? "," : "."
        thousands = decimal_sep == "," ? "." : ","
        return nil unless value.count(decimal_sep) == 1 && value.split(decimal_sep).first.match?(/\A\d{1,3}(#{Regexp.escape(thousands)}\d{3})*\z/)

        value = value.delete(thousands).tr(decimal_sep, ".")
      else
        separator = value.include?(",") ? "," : (value.include?(".") ? "." : nil)

        if separator && value.count(separator) > 1
          return nil unless value.match?(/\A\d{1,3}(#{Regexp.escape(separator)}\d{3})+\z/)

          value = value.delete(separator)
        elsif separator
          integer, decimals = value.split(separator, 2)
          return nil if decimals.to_s.length == 3 && integer.match?(/\A[1-9]\d{0,2}\z/)

          value = "#{integer}.#{decimals}"
        end
      end

      return nil unless value.match?(/\A\d+(\.\d{1,3})?\z/)

      BigDecimal(value)
    end

    def format_quantity(quantity)
      quantity.to_d.to_s("F").sub(/(\.\d*?)0+\z/, '\1').sub(/\.\z/, "").tr(".", ",")
    end

    # Subtotal de un ítem: cantidad exacta x precio unitario en centavos, redondeado a
    # centavo (mitad hacia arriba) con BigDecimal.
    def line_subtotal_cents(quantity, unit_price_cents)
      (quantity.to_d * unit_price_cents.to_i).round(0, half: :up).to_i
    end
  end
end
