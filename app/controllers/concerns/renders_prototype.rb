# Sirve un prototipo de prototypes/*.html (Repartos, MODO DEMOSTRACIÓN). Esos archivos son
# HTML autocontenido SIN <html>/<head>/<body> (traen su propio viewport), para poder
# publicarse igual como página de prueba fuera de HANS; acá se les agrega el esqueleto mínimo
# y la dirección del botón para salir de la prueba. No hacen pedidos al servidor: todo lo que
# "guardan" queda en el navegador (ver test/controllers/reparto/prototype_isolation_test.rb).
module RendersPrototype
  extend ActiveSupport::Concern

  private

  def render_prototype(path, exit_url:)
    body = File.read(path)
    page = <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <head>
      <meta charset="utf-8">
      <meta name="robots" content="noindex">
      <script>window.HANS_EXIT_URL = #{exit_url.to_json};</script>
      </head>
      <body>
      #{body}
      </body>
      </html>
    HTML
    response.headers["Cache-Control"] = "no-store"
    render html: page.html_safe, layout: false
  end
end
