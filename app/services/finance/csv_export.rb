require "csv"

module Finance
  # Exportaciones CSV del módulo (con BOM para Excel). Las celdas de texto que empiezan
  # con = + - @ se neutralizan para evitar inyección de fórmulas al abrir el archivo.
  module CsvExport
    BOM = "﻿".freeze

    module_function

    def generate(headers, rows)
      BOM + CSV.generate(write_headers: true, headers: headers) do |csv|
        rows.each { |row| csv << row.map { |cell| safe(cell) } }
      end
    end

    def safe(cell)
      return cell unless cell.is_a?(String)

      cell.match?(/\A[=+\-@\t\r]/) ? "'#{cell}" : cell
    end

    # Importe exacto en pesos con dos decimales y punto ("1500.00"), sin separador de miles.
    def pesos(cents)
      whole, rest = cents.to_i.abs.divmod(100)
      format("%s%d.%02d", cents.to_i.negative? ? "-" : "", whole, rest)
    end

    def purchases(obligations)
      rows = obligations.map do |o|
        [o.accrual_on.strftime("%d/%m/%Y"), o.supplier&.name, Obligation::DOCUMENT_TYPES[o.document_type], o.document_number, pesos(o.amount_cents), pesos(o.paid_cents),
         pesos([o.balance_cents, 0].max), o.status_label, o.due_on&.strftime("%d/%m/%Y"), o.notes]
      end
      generate(["Fecha", "Proveedor", "Tipo de comprobante", "Número", "Total", "Pagado", "Saldo", "Estado", "Vencimiento", "Comentario"], rows)
    end

    def expenses(obligations)
      rows = obligations.map do |o|
        [o.accrual_on.strftime("%d/%m/%Y"), o.source.expense_category.name, o.supplier&.name, Obligation::DOCUMENT_TYPES[o.document_type], o.document_number, pesos(o.amount_cents),
         pesos(o.paid_cents), pesos([o.balance_cents, 0].max), o.status_label, o.due_on&.strftime("%d/%m/%Y"), o.notes]
      end
      generate(["Fecha", "Categoría", "Proveedor", "Tipo de comprobante", "Número", "Importe", "Pagado", "Saldo", "Estado", "Vencimiento", "Comentario"], rows)
    end

    def supplier_account(account)
      rows = account.entries.map do |e|
        detail = case e.kind
                 when :payment then "Pago #{e.record.method_label}#{" · Ref: #{e.record.reference}" if e.record.reference.present?}#{' (ANULADO)' if e.record.voided?}"
                 else "#{e.kind == :purchase ? 'Compra' : 'Gasto'} #{e.record.document_label}#{' (ANULADO)' if e.record.voided?}"
                 end
        [e.date.strftime("%d/%m/%Y"), { purchase: "Compra", expense: "Gasto", payment: "Pago" }[e.kind], detail, pesos(e.debit_cents), pesos(e.credit_cents), pesos(e.running_cents)]
      end
      generate(["Fecha", "Tipo", "Detalle", "Obligación (debe)", "Pago (haber)", "Saldo neto acumulado"], rows)
    end
  end
end
