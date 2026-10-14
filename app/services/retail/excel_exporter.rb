require "caxlsx"

module Retail
  # Exporta pedidos minoristas a un .xlsx real de dos hojas (solo lectura: nada se modifica):
  #  1. "Detalle de productos": UNA fila por cada ítem de cada pedido (catálogo y manuales),
  #     sin agrupar compradores, para saber quién pidió qué.
  #  2. "Resumen de pedidos": UNA fila por pedido, con subtotal, envío, total, pagado y saldo
  #     (los pagos y el envío salen una sola vez por pedido, nunca por producto).
  # Los pagos son los propios del pedido minorista (RetailOrder#amount_paid_cents, suma de los
  # pagos activos); no tienen relación con la cuenta corriente mayorista.
  # Importes en pesos con formato de moneda; fechas y cantidades como números de Excel.
  class ExcelExporter
    DETAIL_HEADERS = [
      "Pedido", "Fecha de creación", "Fecha de entrega", "Horario", "Comprador", "Teléfono", "Tipo de entrega", "Dirección",
      "Producto", "Tipo de producto", "Cantidad", "Precio unitario", "Subtotal", "Observaciones del pedido", "Estado del pedido", "Estado del pago"
    ].freeze

    SUMMARY_HEADERS = [
      "Pedido", "Fecha de entrega", "Horario", "Comprador", "Teléfono", "Tipo de entrega", "Dirección",
      "Subtotal de productos", "Envío", "Total del pedido", "Total pagado", "Saldo pendiente", "Medio de pago previsto",
      "Estado del pago", "Estado del pedido", "Observaciones"
    ].freeze

    DETAIL_WIDTHS = [10, 16, 16, 18, 28, 16, 14, 30, 36, 16, 10, 16, 16, 40, 16, 14].freeze
    SUMMARY_WIDTHS = [10, 16, 18, 28, 16, 14, 30, 18, 14, 16, 16, 16, 24, 14, 16, 40].freeze

    CONTENT_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze
    # Sin comillas: caxlsx no escapa las comillas dentro del atributo XML y dejaría el archivo inválido.
    CURRENCY_FORMAT = "$#,##0.00".freeze
    DATE_FORMAT = "dd/mm/yyyy".freeze

    def self.filename(date = Date.current)
      "pedidos_minoristas_#{date.iso8601}.xlsx"
    end

    # orders: relación de RetailOrder (ya filtrada). Se ordena y se precargan los ítems acá.
    def initialize(orders)
      @orders = orders.reorder(:delivery_date, :id).includes(:retail_order_items).to_a
    end

    def call
      package = Axlsx::Package.new
      workbook = package.workbook
      styles = build_styles(workbook)

      workbook.add_worksheet(name: "Detalle de productos") { |sheet| build_detail(sheet, styles) }
      workbook.add_worksheet(name: "Resumen de pedidos") { |sheet| build_summary(sheet, styles) }

      package.to_stream.read
    end

    private

    attr_reader :orders

    def build_styles(workbook)
      s = workbook.styles
      base = { font_name: "Calibri", sz: 11 }
      {
        header: s.add_style(base.merge(b: true, fg_color: "FFFFFF", bg_color: "5B3A29", alignment: { horizontal: :center, vertical: :center, wrap_text: true })),
        text: s.add_style(base.merge(alignment: { vertical: :top, wrap_text: true })),
        date: s.add_style(base.merge(format_code: DATE_FORMAT, alignment: { horizontal: :center, vertical: :top })),
        integer: s.add_style(base.merge(format_code: "0", alignment: { vertical: :top })),
        money: s.add_style(base.merge(format_code: CURRENCY_FORMAT, alignment: { vertical: :top }))
      }
    end

    def build_detail(sheet, styles)
      sheet.add_row DETAIL_HEADERS, style: styles[:header], height: 32
      column_types = %i[text date date text text text text text text text integer money money text text text]

      orders.each do |order|
        order.retail_order_items.each do |item|
          row = [
            order.number, order.created_at.in_time_zone.to_date, order.delivery_date, order.delivery_time_note.to_s, order.buyer_name, order.buyer_phone.to_s,
            order.delivery_kind_label, order.address.to_s, item.display_name, item.catalog? ? "Catálogo" : "Manual", item.quantity,
            pesos(item.unit_price_cents), pesos(item.line_total_cents), order.notes.to_s, order.status_label, order.payment_status_label
          ]
          add_data_row(sheet, row, column_types, styles)
        end
      end

      finish_sheet(sheet, DETAIL_HEADERS.size, DETAIL_WIDTHS)
    end

    def build_summary(sheet, styles)
      sheet.add_row SUMMARY_HEADERS, style: styles[:header], height: 32
      column_types = %i[text date text text text text text money money money money money text text text text]

      orders.each do |order|
        row = [
          order.number, order.delivery_date, order.delivery_time_note.to_s, order.buyer_name, order.buyer_phone.to_s, order.delivery_kind_label, order.address.to_s,
          pesos(order.subtotal_cents), pesos(order.shipping_cents), pesos(order.total_cents), pesos(order.amount_paid_cents), pesos(order.pending_balance_cents),
          order.planned_payment_method_label.to_s, order.payment_status_label, order.status_label, order.notes.to_s
        ]
        add_data_row(sheet, row, column_types, styles)
      end

      finish_sheet(sheet, SUMMARY_HEADERS.size, SUMMARY_WIDTHS)
    end

    # Los textos se escriben SIEMPRE como string (nunca se interpretan como fórmula, aunque
    # empiecen con "=", "+", "-" o "@"), así la descripción de un producto manual queda exacta.
    def add_data_row(sheet, values, column_types, styles)
      types = column_types.map { |type| type == :text ? :string : nil }
      sheet.add_row values, style: column_types.map { |type| styles[type] }, types: types
    end

    def finish_sheet(sheet, column_count, widths)
      last_row = sheet.rows.size
      sheet.auto_filter = "A1:#{column_letter(column_count)}#{[last_row, 1].max}"
      sheet.column_widths(*widths)
      sheet.sheet_view.pane do |pane|
        pane.state = :frozen
        pane.y_split = 1
        pane.top_left_cell = "A2"
        pane.active_pane = :bottom_left
      end
    end

    def column_letter(number)
      Axlsx.col_ref(number - 1)
    end

    # Centavos enteros -> pesos para Excel (número con 2 decimales, sin acumular errores de punto flotante).
    def pesos(cents)
      (cents.to_i / 100.0).round(2)
    end
  end
end
