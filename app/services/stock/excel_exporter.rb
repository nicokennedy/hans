require "caxlsx"

module Stock
  # Planilla de control físico de stock (.xlsx real, hoja "Control de Stock"). Solo lectura:
  # recibe las fotos ya armadas por Stock::Availability (las MISMAS que muestra el panel) y no
  # recalcula nada. Una fila por StockItem activo, ordenadas alfabéticamente para contar en la
  # fábrica. "Conteo real" y "Observaciones" quedan vacías para completar a mano; "Diferencia"
  # es una fórmula (Conteo real - Stock físico) que queda vacía mientras no haya conteo.
  # Completar el archivo no toca HANS: los ajustes se siguen registrando con "Contar".
  class ExcelExporter
    SHEET_NAME = "Control de Stock".freeze
    HEADERS = [
      "Producto", "Unidad", "Stock físico", "Salidas pendientes hoy", "Comprometido futuro", "Stock disponible",
      "Stock mínimo", "Producir", "Conteo real", "Diferencia", "Observaciones"
    ].freeze
    WIDTHS = [36, 9, 13, 14, 14, 14, 13, 12, 14, 13, 40].freeze
    PHYSICAL_COL = "C".freeze
    COUNT_COL = "I".freeze
    DIFF_COL = "J".freeze

    CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
    # General: muestra 40 o 2.5 tal cual (un formato "0.###" deja "40." en Excel).
    NUMBER_FORMAT = "General".freeze

    def self.filename(at = Time.current)
      "HANS_Control_Stock_#{at.in_time_zone.to_date.iso8601}.xlsx"
    end

    def initialize(snapshots, generated_at: Time.current)
      @snapshots = snapshots.sort_by { |snapshot| sort_key(snapshot.name) }
      @generated_at = generated_at.in_time_zone
    end

    def call
      package = Axlsx::Package.new
      package.core.created = @generated_at
      package.workbook.add_worksheet(name: SHEET_NAME) { |sheet| build(sheet, build_styles(package.workbook)) }
      package.to_stream.read
    end

    private

    attr_reader :snapshots, :generated_at

    def build_styles(workbook)
      s = workbook.styles
      base = { font_name: "Calibri", sz: 11, alignment: { vertical: :center } }
      {
        header: s.add_style(base.merge(b: true, fg_color: "FFFFFF", bg_color: "5B3A29", alignment: { horizontal: :center, vertical: :center, wrap_text: true })),
        text: s.add_style(base),
        number: s.add_style(base.merge(format_code: NUMBER_FORMAT)),
        count: s.add_style(base.merge(format_code: NUMBER_FORMAT, bg_color: "FFF6D5", border: { style: :thin, color: "E0C97A" })),
        diff: s.add_style(base.merge(format_code: NUMBER_FORMAT, b: true)),
        notes: s.add_style(base.merge(alignment: { vertical: :center, wrap_text: true })),
        footer: s.add_style(font_name: "Calibri", sz: 10, i: true, fg_color: "666666"),
        diff_mismatch: s.add_style(bg_color: "F8D7DA", fg_color: "9C0006", type: :dxf),
        diff_match: s.add_style(bg_color: "D4EDDA", fg_color: "006100", type: :dxf)
      }
    end

    def build(sheet, styles)
      sheet.add_row HEADERS, style: styles[:header], height: 32

      snapshots.each do |snapshot|
        row = sheet.rows.size + 1
        values = [
          snapshot.name.to_s.strip, snapshot.unit.to_s,
          number(snapshot.physical_quantity), number(pending_today(snapshot)), number(snapshot.future_committed),
          number(snapshot.available_quantity), number(snapshot.minimum_quantity), number(to_produce(snapshot)),
          nil, %(=IF(#{COUNT_COL}#{row}="","",#{COUNT_COL}#{row}-#{PHYSICAL_COL}#{row})), nil
        ]
        sheet.add_row values,
          style: [styles[:text], styles[:text]] + [styles[:number]] * 6 + [styles[:count], styles[:diff], styles[:notes]],
          # Nombre y unidad SIEMPRE como texto (nunca se interpretan como fórmula); el resto, números.
          types: [:string, :string, :float, :float, :float, :float, :float, :float, nil, nil, :string],
          # caxlsx escapa por defecto todo lo que empieza con "=": solo la celda Diferencia es fórmula.
          escape_formulas: HEADERS.map { |header| header != "Diferencia" },
          # Valor inicial de la fórmula (vacío: todavía no hay conteo); al abrir se recalcula.
          formula_values: HEADERS.map { |header| header == "Diferencia" ? "" : nil }
      end

      last = [sheet.rows.size, 2].max
      add_diff_highlighting(sheet, styles, last)
      sheet.auto_filter = "A1:#{DIFF_COL.next}#{last}"
      sheet.column_widths(*WIDTHS)
      sheet.sheet_view.pane do |pane|
        pane.state = :frozen
        pane.y_split = 1
        pane.top_left_cell = "A2"
        pane.active_pane = :bottom_left
      end
      sheet.page_setup.set(orientation: :landscape, fit_to_width: 1, fit_to_height: 0)
      sheet.print_options.grid_lines = true

      sheet.add_row []
      sheet.add_row ["Generado por HANS el #{I18n.l(generated_at, format: '%d/%m/%Y %H:%M')} (hora de Argentina). " \
                     "Completar \"Conteo real\"; \"Diferencia\" = Conteo real - Stock físico. " \
                     "Este archivo no modifica HANS: los ajustes se registran con \"Contar\" en el panel de Stock."], style: styles[:footer]
    end

    # Rojo si el conteo difiere del físico, verde si coincide; sin conteo, sin color.
    def add_diff_highlighting(sheet, styles, last)
      range = "#{DIFF_COL}2:#{DIFF_COL}#{last}"
      sheet.add_conditional_formatting(range, type: :expression, priority: 1, dxfId: styles[:diff_mismatch],
        formula: %(AND($#{COUNT_COL}2<>"",$#{DIFF_COL}2<>0)))
      sheet.add_conditional_formatting(range, type: :expression, priority: 2, dxfId: styles[:diff_match],
        formula: %(AND($#{COUNT_COL}2<>"",$#{DIFF_COL}2=0)))
    end

    # Lo que todavía falta descontar del físico hoy: las salidas de hoy antes del corte de las
    # 13:00; después ya están materializadas en el físico (mismo criterio que Stock::Availability,
    # así Disponible = Físico - Comprometido futuro - Salidas pendientes hoy).
    def pending_today(snapshot)
      snapshot.today_dispatch_materialized ? 0 : snapshot.today_dispatch
    end

    # La misma cifra que el panel destaca: "PREPARAR n tandas → x" si el ítem tiene lote,
    # si no "PRODUCIR x"; 0 si no hace falta producir.
    def to_produce(snapshot)
      return 0 unless snapshot.production_needed.positive?

      snapshot.production_batch_size ? snapshot.production_suggested : snapshot.production_needed
    end

    # BigDecimal -> número de Excel sin errores de punto flotante (40 queda 40, 2.5 queda 2.5).
    def number(value)
      decimal = value.to_d
      decimal.frac.zero? ? decimal.to_i : decimal.to_f
    end

    def sort_key(name)
      I18n.transliterate(name.to_s.strip).downcase
    end
  end
end
