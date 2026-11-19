module Users
  # Contraseña temporal segura para entregarle al usuario (se muestra UNA vez al admin y solo
  # se guarda su hash). 12 caracteres sin letras ni números que se confunden (0/O, 1/l/I),
  # en tres grupos para dictarla o copiarla: "Kx7p-Qm4t-Zr9w" (~70 bits).
  module TemporaryPassword
    ALPHABET = (("a".."z").to_a + ("A".."Z").to_a + ("2".."9").to_a - %w[l o I O]).freeze

    module_function

    def generate
      Array.new(3) { Array.new(4) { ALPHABET[SecureRandom.random_number(ALPHABET.size)] }.join }.join("-")
    end
  end
end
