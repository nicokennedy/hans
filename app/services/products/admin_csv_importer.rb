require "csv"
require "bigdecimal"

module Products
  class AdminCsvImporter
    EXPECTED_HEADERS = ["NOMBRE", "COSTO X U", "PRECIO MAY", "Categoría"].freeze
    CATEGORY_NAMES = {
      "AL" => "Alfajores",
      "BU" => "Budines",
      "CO" => "Cookies",
      "CU" => "Cuadrados",
      "MA" => "Macarons",
      "MI" => "Mini tortas",
      "ZF" => "Fríos",
      "OT" => "Otros",
      "PO" => "Postres"
    }.freeze

    Row = Struct.new(
      :line_number,
      :status,
      :name,
      :price,
      :cost,
      :category_name,
      :internal_category,
      :changes,
      :errors,
      keyword_init: true
    )

    Result = Struct.new(:rows, keyword_init: true) do
      def new_rows
        rows.select { |row| row.status == :new }
      end

      def updated_rows
        rows.select { |row| row.status == :updated }
      end

      def unchanged_rows
        rows.select { |row| row.status == :unchanged }
      end

      def error_rows
        rows.select { |row| row.status == :error }
      end
    end

    def initialize(path:, apply: false)
      @path = Pathname.new(path.to_s)
      @apply = apply
      @header_map = {}
    end

    def call
      raise Errno::ENOENT, path.to_s unless path.exist?

      result = Result.new(rows: [])

      ActiveRecord::Base.transaction do
        CSV.foreach(path, headers: true, encoding: "bom|utf-8").with_index(2) do |csv_row, line_number|
          capture_headers(csv_row) if header_map.empty?
          row = process_row(csv_row, line_number)
          result.rows << row if row.present?
        end

        raise ActiveRecord::Rollback unless apply
      end

      result
    rescue CSV::MalformedCSVError => e
      Result.new(rows: [
        Row.new(
          line_number: nil,
          status: :error,
          errors: ["El archivo CSV no se pudo leer: #{e.message}"]
        )
      ])
    end

    private

    attr_reader :path, :apply, :header_map

    def process_row(csv_row, line_number)
      missing_headers = EXPECTED_HEADERS.reject { |header| header_map.key?(header) }

      if missing_headers.any?
        return Row.new(
          line_number: line_number,
          status: :error,
          errors: ["Faltan columnas: #{missing_headers.join(', ')}"]
        )
      end

      name = value_for(csv_row, "NOMBRE")
      category_code = value_for(csv_row, "Categoría").upcase
      category_name = public_category_name(category_code)
      price_value = value_for(csv_row, "PRECIO MAY")
      cost_value = value_for(csv_row, "COSTO X U")

      return nil if [name, category_code, price_value, cost_value].all?(&:blank?)

      price_cents = money_to_cents(price_value)
      cost_cents = money_to_cents(cost_value)
      errors = row_errors(name, category_code, price_cents, cost_cents)

      if errors.any?
        return Row.new(
          line_number: line_number,
          status: :error,
          name: name,
          price: price_value,
          cost: cost_value,
          category_name: category_name,
          internal_category: category_code,
          errors: errors
        )
      end

      product = Product.includes(:category).find_by(name: name)
      row = build_preview_row(
        product: product,
        line_number: line_number,
        name: name,
        category_name: category_name,
        internal_category: category_code,
        price_cents: price_cents,
        cost_cents: cost_cents
      )

      apply_row(row, product, price_cents, cost_cents) if apply && [:new, :updated].include?(row.status)

      row
    rescue => e
      Row.new(
        line_number: line_number,
        status: :error,
        name: name,
        errors: [e.message]
      )
    end

    def capture_headers(csv_row)
      csv_row.headers.each do |header|
        EXPECTED_HEADERS.each do |expected|
          header_map[expected] ||= header if header_matches?(header, expected)
        end
      end
    end

    def header_matches?(header, expected)
      normalized_header = normalize_header(header)
      normalized_expected = normalize_header(expected)

      normalized_header == normalized_expected ||
        (expected == "PRECIO MAY" && normalized_header.start_with?(normalized_expected))
    end

    def normalize_header(value)
      value.to_s
        .delete_prefix("\uFEFF")
        .strip
        .upcase
    end

    def value_for(csv_row, header)
      csv_row[header_map[header]].to_s.strip
    end

    def row_errors(name, category_code, price_cents, cost_cents)
      errors = []
      errors << "NOMBRE no puede estar en blanco" if name.blank?
      errors << "Categoría no puede estar en blanco" if category_code.blank?
      errors << "PRECIO MAY no puede estar en blanco" if price_cents.nil?
      errors << "PRECIO MAY no puede ser negativo" if price_cents.to_i.negative?
      errors << "COSTO X U no puede ser negativo" if cost_cents.to_i.negative?
      errors
    end

    def build_preview_row(product:, line_number:, name:, category_name:, internal_category:, price_cents:, cost_cents:)
      if product.blank?
        return Row.new(
          line_number: line_number,
          status: :new,
          name: name,
          price: format_money(price_cents),
          cost: format_money(cost_cents),
          category_name: category_name,
          internal_category: internal_category,
          changes: ["Producto nuevo"],
          errors: []
        )
      end

      changes = changes_for(product, category_name, internal_category, price_cents, cost_cents)
      status = changes.any? ? :updated : :unchanged

      Row.new(
        line_number: line_number,
        status: status,
        name: name,
        price: format_money(price_cents),
        cost: format_money(cost_cents),
        category_name: category_name,
        internal_category: internal_category,
        changes: changes,
        errors: []
      )
    end

    def changes_for(product, category_name, internal_category, price_cents, cost_cents)
      changes = []

      if product.price_cents.to_i != price_cents.to_i
        changes << "Precio: #{format_money(product.price_cents)} -> #{format_money(price_cents)}"
      end

      if product.cost_cents != cost_cents
        changes << "Costo: #{format_money(product.cost_cents)} -> #{format_money(cost_cents)}"
      end

      if product.category&.name != category_name
        changes << "Categoría cliente: #{product.category&.name.presence || '-'} -> #{category_name}"
      end

      if product.internal_category.to_s != internal_category.to_s
        changes << "Categoría interna: #{product.internal_category.presence || '-'} -> #{internal_category}"
      end

      changes
    end

    def apply_row(row, product, price_cents, cost_cents)
      category = Category.find_or_create_by!(name: row.category_name)
      product ||= Product.new(name: row.name, active: true)

      product.update!(
        price_cents: price_cents,
        cost_cents: cost_cents,
        category: category,
        internal_category: row.internal_category
      )
    end

    def public_category_name(category_code)
      CATEGORY_NAMES[category_code] || "Otros"
    end

    def money_to_cents(value)
      normalized = value.to_s
        .delete("$")
        .strip

      return nil if normalized.blank?

      normalized = normalize_decimal_separator(normalized)
      (BigDecimal(normalized) * 100).round.to_i
    end

    def normalize_decimal_separator(value)
      if value.include?(",")
        value.delete(".").tr(",", ".")
      else
        value
      end
    end

    def format_money(cents)
      return "-" if cents.nil?

      amount = cents.to_i / 100.0
      (amount % 1).zero? ? amount.to_i.to_s : format("%.2f", amount)
    end
  end
end
