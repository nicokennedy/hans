require "caxlsx"

module Customers
  # Excel de direcciones de clientes mayoristas (Administración → Clientes → Exportar
  # clientes). Una fila por cliente, activos e inactivos. Solo identificación y datos de
  # entrega: sin email, notas internas, condiciones de pago ni datos financieros.
  # Las columnas de dirección se completan y se vuelven a importar por consola
  # (Customers::AddressImport, ver docs/CLIENTES_DIRECCIONES.md).
  class AddressExport
    SHEET_NAME = "Clientes".freeze
    ID_HEADER = "ID cliente (NO MODIFICAR)".freeze
    NAME_HEADER = "Nombre".freeze
    STATUS_HEADER = "Estado".freeze
    PHONE_HEADER = "Teléfono".freeze
    CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

    def self.filename(at = Time.current)
      "HANS_Clientes_Direcciones_#{at.in_time_zone.to_date.iso8601}.xlsx"
    end

    def self.headers
      [ID_HEADER, NAME_HEADER, STATUS_HEADER] + AddressFields::ALL.map(&:header) + [PHONE_HEADER]
    end

    def initialize(customers = Customer.all, generated_at: Time.current)
      @customers = customers.order(Arel.sql("lower(customers.name)"), :id).to_a
      @generated_at = generated_at.in_time_zone
    end

    def call
      package = Axlsx::Package.new
      package.core.created = @generated_at
      styles = build_styles(package.workbook)
      package.workbook.add_worksheet(name: SHEET_NAME) { |sheet| build_customers(sheet, styles) }
      package.workbook.add_worksheet(name: "Instrucciones") { |sheet| build_instructions(sheet, styles) }
      package.to_stream.read
    end

    private

    def build_styles(workbook)
      s = workbook.styles
      base = { font_name: "Calibri", sz: 11, alignment: { vertical: :center } }
      header = base.merge(b: true, alignment: { horizontal: :center, vertical: :center, wrap_text: true }, border: { style: :thin, color: "999999" })
      {
        header_locked: s.add_style(header.merge(fg_color: "FFFFFF", bg_color: "6B6B6B")),
        header_edit: s.add_style(header.merge(fg_color: "1F1F1F", bg_color: "FFE699")),
        locked: s.add_style(base.merge(fg_color: "555555", bg_color: "EDEDED")),
        id: s.add_style(base.merge(b: true, fg_color: "555555", bg_color: "EDEDED", alignment: { horizontal: :center, vertical: :center })),
        edit: s.add_style(base.merge(alignment: { vertical: :center, wrap_text: true })),
        title: s.add_style(font_name: "Calibri", sz: 14, b: true),
        text: s.add_style(font_name: "Calibri", sz: 11, alignment: { wrap_text: true, vertical: :top })
      }
    end

    def build_customers(sheet, styles)
      headers = self.class.headers
      editable = AddressFields::ALL.map(&:header)
      sheet.add_row headers, height: 36,
        style: headers.map { |h| editable.include?(h) ? styles[:header_edit] : styles[:header_locked] }

      @customers.each do |customer|
        values = [customer.id, customer.name.to_s.strip, customer.active? ? "Activo" : "Inactivo"] +
          AddressFields::ALL.map { |field| field.stored? ? customer[field.column].to_s.strip.presence : nil } +
          [customer.phone.to_s.strip.presence]
        sheet.add_row values,
          types: [:integer] + [:string] * (headers.size - 1),
          style: [styles[:id], styles[:locked], styles[:locked]] + [styles[:edit]] * editable.size + [styles[:locked]]
      end

      sheet.column_widths(*([16, 34, 11] + AddressFields::ALL.map(&:width) + [18]))
      last_col = Axlsx.col_ref(headers.size - 1)
      sheet.auto_filter = "A1:#{last_col}#{[@customers.size + 1, 2].max}"
      sheet.sheet_view.pane do |pane|
        pane.top_left_cell = "A2"
        pane.state = :frozen
        pane.y_split = 1
        pane.active_pane = :bottom_left
      end
    end

    def build_instructions(sheet, styles)
      pending = AddressFields.pending.map(&:header)
      lines = [
        "Cómo completar las direcciones",
        "1. Completá o corregí SOLO las columnas amarillas (dirección de entrega).",
        "2. No cambies la columna \"#{ID_HEADER}\": es la que identifica a cada cliente. Las columnas grises no se importan.",
        "3. Una celda vacía no borra nada: deja el dato que ya tiene HANS.",
        "4. Dirección: calle y número (ej. Av. Colón 2345). Si no tiene número, escribí S/N.",
        "5. Provincia: el nombre de la provincia (ej. Buenos Aires). Código postal: 7600 o B7600ABC.",
        "6. Referencias de entrega: datos útiles para el repartidor (ej. \"Entrar por el costado, preguntar por Marta\").",
        "7. No agregues ni borres filas de clientes: los clientes nuevos se crean desde HANS.",
        (pending.any? ? "Nota: #{pending.join(', ')} todavía no se guardan en HANS; se van a importar cuando se agreguen esos campos." : nil),
        "Generado el #{I18n.l(@generated_at, format: '%d/%m/%Y %H:%M')}. #{@customers.size} clientes."
      ].compact

      sheet.add_row [lines.first], style: styles[:title]
      lines.drop(1).each { |line| sheet.add_row [line], style: styles[:text] }
      sheet.column_widths 110
    end
  end
end
