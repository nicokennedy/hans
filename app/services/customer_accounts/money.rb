module CustomerAccounts
  # Importes de cuenta corriente: SIEMPRE en centavos enteros, sin floats. Se escriben
  # en pesos ("300000", "300.000", "$ 300.000", "1.500,50"). Un texto ambiguo o con
  # letras no se adivina: devuelve nil y el formulario lo rechaza.
  module Money
    module_function

    def parse_pesos(text)
      value = text.to_s.delete("$").gsub(/\s+/, "")
      return nil if value.empty?

      if value.match?(/\A\d+\z/) || value.match?(/\A\d{1,3}([.,]\d{3})+\z/)
        value.delete(".,").to_i * 100
      elsif (m = value.match(/\A(\d{1,3}(?:\.\d{3})*|\d+),(\d{1,2})\z/))
        m[1].delete(".").to_i * 100 + m[2].ljust(2, "0").to_i
      elsif (m = value.match(/\A(\d+)\.(\d{1,2})\z/))
        m[1].to_i * 100 + m[2].ljust(2, "0").to_i
      end
    end

    # 30000000 -> "300.000" ; 150050 -> "1.500,50"
    def format_pesos(cents)
      whole, rest = cents.to_i.abs.divmod(100)
      digits = whole.to_s.reverse.scan(/\d{1,3}/).join(".").reverse
      sign = cents.to_i.negative? ? "-" : ""
      rest.zero? ? "#{sign}#{digits}" : "#{sign}#{digits},#{rest.to_s.rjust(2, '0')}"
    end
  end
end
