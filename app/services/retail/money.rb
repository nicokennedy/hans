module Retail
  # Importes del módulo minorista: centavos ENTEROS, nunca floats. Mismo parser de pesos que
  # cuenta corriente / administración.
  module Money
    module_function

    def parse_pesos(text)
      CustomerAccounts::Money.parse_pesos(text)
    end

    def format_pesos(cents)
      CustomerAccounts::Money.format_pesos(cents)
    end
  end
end
