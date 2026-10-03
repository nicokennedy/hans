require "test_helper"

# Corre los tests de los módulos JS puros (armado de hojas A4 y escritor de
# PDF de la impresión masiva de remitos) dentro de la suite de Rails, así
# `bin/rails test` los cubre. Se saltan si no hay Node instalado.
class JavascriptModulesTest < ActiveSupport::TestCase
  test "node --test passes for the receipt layout and PDF writer modules" do
    skip "Node no está disponible en este entorno" unless system("which node > /dev/null 2>&1")

    files = Dir[Rails.root.join("test/javascript/*.test.mjs")]
    assert files.any?, "no se encontraron tests JS"

    output = IO.popen(["node", "--test", *files], err: [:child, :out], &:read)
    assert $?.success?, "fallaron los tests JS:\n#{output}"
  end
end
