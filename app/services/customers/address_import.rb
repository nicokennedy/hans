module Customers
  # Importa por consola las direcciones de entrega completadas en el Excel de
  # Customers::AddressExport. Reglas (ver docs/CLIENTES_DIRECCIONES.md):
  #
  #  - Identifica cada fila SOLO por el ID; además el Nombre de la fila tiene que coincidir con
  #    el del cliente (protege contra un ID tocado por error). Nunca crea ni borra clientes.
  #  - Solo actualiza los campos de Customers::AddressFields que existen en la base. Nombre,
  #    estado, teléfono y cualquier otra columna se ignoran (se avisa si cambiaron).
  #  - Una celda vacía no borra nada.
  #  - IDs repetidos, IDs inexistentes, nombres que no coinciden o valores inválidos: la fila
  #    entera se descarta y se informa.
  #  - call(apply: false) es el dry run: no escribe nada. call(apply: true) escribe todo en UNA
  #    transacción (o nada): si un cliente cambió desde el dry run, no se aplica ningún cambio.
  class AddressImport
    Change = Struct.new(:row, :customer_id, :customer_name, :field, :from, :to, keyword_init: true)
    Issue = Struct.new(:row, :customer_id, :message, keyword_init: true)

    class Result
      attr_reader :changes, :errors, :warnings, :pending, :rows_read, :applied

      def initialize(changes:, errors:, warnings:, pending:, rows_read:, applied:)
        @changes, @errors, @warnings, @pending, @rows_read, @applied = changes, errors, warnings, pending, rows_read, applied
      end

      def customers_to_update
        changes.map(&:customer_id).uniq.size
      end
    end

    class Aborted < StandardError; end

    IGNORED_HEADERS = {
      AddressExport::STATUS_HEADER => ->(customer) { customer.active? ? "Activo" : "Inactivo" },
      AddressExport::PHONE_HEADER => ->(customer) { customer.phone.to_s.strip }
    }.freeze

    def initialize(data)
      @data = data
    end

    def call(apply: false)
      rows = XlsxRows.new(@data).rows(AddressExport::SHEET_NAME)
      header = rows.shift.to_a.map { |h| h.to_s.squish }
      index = locate_columns(header)

      errors, warnings, pending, candidates = [], [], [], []
      data_rows = rows.each_with_index.map { |cells, i| [i + 2, cells] }.reject { |_, cells| cells.all?(&:blank?) }

      ids = data_rows.map { |line, cells| [line, parse_id(cells[index[:id]])] }
      duplicated = ids.map(&:last).compact.tally.select { |_, count| count > 1 }.keys
      customers = Customer.where(id: ids.map(&:last).compact).index_by(&:id)

      data_rows.each_with_index do |(line, cells), i|
        id = ids[i].last
        if id.nil?
          errors << Issue.new(row: line, customer_id: nil, message: "El ID \"#{cells[index[:id]]}\" no es un número de cliente.")
          next
        end
        if duplicated.include?(id)
          errors << Issue.new(row: line, customer_id: id, message: "El ID #{id} está repetido en el Excel: no se importa ninguna de esas filas.")
          next
        end
        customer = customers[id]
        unless customer
          errors << Issue.new(row: line, customer_id: id, message: "No existe un cliente con ID #{id} (no se crean clientes).")
          next
        end
        row_name = cells[index[:name]].to_s
        if row_name.present? && AddressFields.fold(row_name) != AddressFields.fold(customer.name)
          errors << Issue.new(row: line, customer_id: id, message: "El nombre \"#{row_name.squish}\" no coincide con el cliente #{id} (\"#{customer.name}\"). ¿Se modificó el ID?")
          next
        end

        IGNORED_HEADERS.each do |header_name, current|
          col = header.index(header_name)
          next if col.nil? || cells[col].blank? || cells[col].to_s.squish == current.call(customer)

          warnings << Issue.new(row: line, customer_id: id, message: "Se ignoró el cambio en \"#{header_name}\" (no se modifica desde este Excel).")
        end

        row_changes, row_errors = [], []
        AddressFields::ALL.each do |field|
          col = index[:fields][field.column]
          next if col.nil? || cells[col].blank?
          # Lo que ya tiene HANS no se valida ni se toca (ej. una dirección vieja sin número):
          # solo se revisan los valores nuevos.
          next if field.stored? && cells[col].to_s.squish == customer[field.column].to_s.squish

          value, problem = AddressFields.normalize(field, cells[col])
          if problem
            row_errors << "#{field.header}: \"#{cells[col].to_s.squish}\" #{problem}."
          elsif !field.stored?
            pending << Issue.new(row: line, customer_id: id, message: "#{field.header}: \"#{value}\" (el campo todavía no existe en HANS; no se guarda).")
          elsif value != customer[field.column].to_s.strip
            row_changes << Change.new(row: line, customer_id: id, customer_name: customer.name, field: field, from: customer[field.column], to: value)
          end
        end

        if row_errors.any?
          errors << Issue.new(row: line, customer_id: id, message: "#{customer.name}: #{row_errors.join(' ')} No se importa esta fila.")
        else
          candidates.concat(row_changes)
        end
      end

      write(candidates) if apply && candidates.any?
      Result.new(changes: candidates, errors: errors, warnings: warnings, pending: pending, rows_read: data_rows.size, applied: apply && candidates.any?)
    end

    private

    def locate_columns(header)
      id_col = header.index(AddressExport::ID_HEADER)
      raise Aborted, "No se encontró la columna \"#{AddressExport::ID_HEADER}\" en la hoja #{AddressExport::SHEET_NAME}. Usá el Excel exportado desde HANS." unless id_col

      fields = AddressFields::ALL.to_h { |field| [field.column, header.index(field.header)] }
      raise Aborted, "El Excel no tiene ninguna columna de dirección." if fields.values.compact.empty?

      { id: id_col, name: header.index(AddressExport::NAME_HEADER), fields: fields }
    end

    def parse_id(raw)
      text = raw.to_s.strip.sub(/\.0+\z/, "")
      text.match?(/\A\d+\z/) ? text.to_i : nil
    end

    # Todo o nada. Cada cliente se bloquea y se verifica que su valor siga siendo el del dry run.
    def write(changes)
      Customer.transaction do
        changes.group_by(&:customer_id).each do |id, customer_changes|
          customer = Customer.lock.find(id)
          customer_changes.each do |change|
            next if customer[change.field.column] == change.from

            raise Aborted, "El cliente #{id} (#{customer.name}) cambió su #{change.field.header.downcase} después del dry run. No se aplicó ningún cambio: volvé a correr el dry run."
          end
          customer.update_columns(customer_changes.to_h { |c| [c.field.column, c.to] }.merge("updated_at" => Time.current))
        end
      end
    end
  end
end
