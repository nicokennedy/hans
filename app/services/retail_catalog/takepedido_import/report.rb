module RetailCatalog
  class TakepedidoImport
    # Reporte en texto plano (consola) del resultado de una importación o simulación.
    class Report
      ACTIONS = { create: "Crear", update: "Actualizar", needs_update: "Existe: requiere UPDATE_EXISTING", unchanged: "Existe: sin cambios" }.freeze

      def initialize(importer)
        @importer = importer
      end

      def text
        s = @importer.summary
        lines = []
        lines << "Registros del CSV: #{s[:records]} | Productos finales: #{s[:products]} | Variantes: #{s[:variants]}"
        lines << "Nuevos: #{s[:created]} | Actualizados: #{s[:updated]} | Existentes que requieren autorización: #{s[:needs_update]} | Sin cambios: #{s[:unchanged]}"
        lines << "Productos ocultos: #{s[:hidden_products]} (de temporada: #{s[:seasonal]}) | Variantes deshabilitadas: #{s[:disabled_variants]} | Sin descripción: #{s[:missing_descriptions]}"
        lines << "Categorías nuevas: #{s[:categories_created].presence&.join(', ') || 'ninguna'}"
        lines << ""
        lines << %w[Producto Descripción Categoría Variante Precio Disponibilidad Acción Origen].join(" | ")
        @importer.actions.each do |action|
          group = action.group
          visible = !group.seasonal && group.rows.any?(&:available)
          group.rows.each_with_index do |row, i|
            lines << [
              i.zero? ? group.name : "″", i.zero? ? (group.description.to_s.squish.truncate(60).presence || (group.variant_descriptions ? "(por variante)" : "—")) : "″", group.category,
              row.size || "Única", money(row.price_cents),
              [row.available ? "Habilitada" : "Deshabilitada", (row.stock_managed ? "stock #{row.stock_quantity}" : "sin límite"), (visible ? nil : "producto oculto")].compact.join(", "),
              ACTIONS.fetch(action.kind), row.ref
            ].join(" | ")
          end
          group.rows.each { |row| lines << "    #{row.size}: #{row.description.squish.truncate(90)}" } if group.variant_descriptions
          shown = group.rows.select(&:available).last || group.rows.last
          lines << "    Precio en catálogo: #{money(shown.price_cents)} (#{shown.size || 'única'})" if group.rows.size > 1
          group.notes.each { |note| lines << "    ! #{note}" }
          action.details.each { |detail| lines << "    ≠ #{detail}" }
        end
        lines.join("\n")
      end

      private

      def money(cents)
        "$#{Retail::Money.format_pesos(cents)}"
      end
    end
  end
end
