# Sirve un prototipo de prototypes/*.html (R1 de Repartos). Esos archivos son HTML
# autocontenido SIN <html>/<head>/<body> (traen su propio viewport), para poder publicarse igual como página de prueba
# fuera de HANS; acá se les agrega el esqueleto mínimo. No leen ni escriben la base.
module RendersPrototype
  extend ActiveSupport::Concern

  private

  def render_prototype(path)
    body = File.read(path)
    page = <<~HTML
      <!DOCTYPE html>
      <html lang="es">
      <head>
      <meta charset="utf-8">
      <meta name="robots" content="noindex">
      </head>
      <body>
      #{body}
      </body>
      </html>
    HTML
    render html: page.html_safe, layout: false
  end
end
