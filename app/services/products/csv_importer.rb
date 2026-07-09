require "csv"
require "bigdecimal"

module Products
  class CsvImporter
    DEFAULT_PATH = Rails.root.join("db/products.csv")
    Result = Struct.new(:created, :updated, :errors, keyword_init: true)

    def initialize(path: DEFAULT_PATH, dry_run: false)
      @path = Pathname.new(path.to_s)
      @dry_run = dry_run
      @result = Result.new(created: 0, updated: 0, errors: [])
    end

    def call
      raise Errno::ENOENT, path.to_s unless path.exist?

      ActiveRecord::Base.transaction do
        CSV.foreach(path, headers: true).with_index(2) do |row, line_number|
          import_row(row, line_number)
        end

        raise ActiveRecord::Rollback if dry_run
      end

      result
    end

    private

    attr_reader :path, :dry_run, :result

    def import_row(row, line_number)
      name = row["name"].to_s.strip
      category_name = row["category_name"].to_s.strip

      if name.blank?
        add_error(line_number, "name no puede estar en blanco")
        return
      end

      if category_name.blank?
        add_error(line_number, "category_name no puede estar en blanco")
        return
      end

      product = find_product(row, name)
      new_record = product.new_record?
      category = Category.find_or_create_by!(name: category_name)

      product.assign_attributes(
        name: name,
        category: category,
        internal_category: blank_to_nil(row["internal_category"]),
        public_category: blank_to_nil(row["public_category"]),
        price_cents: money_to_cents(row["price"]),
        cost_cents: money_to_cents(row["cost"]),
        active: boolean_value(row["active"]),
        position: integer_value(row["position"]),
        unit: blank_to_nil(row["unit"]),
        description: blank_to_nil(row["description"])
      )

      product.save!

      if new_record
        result.created += 1
      else
        result.updated += 1
      end
    rescue => e
      add_error(line_number, e.message)
    end

    def find_product(row, name)
      id = row["id"].to_s.strip

      if id.present?
        Product.find_by(id: id) || Product.new
      else
        Product.find_or_initialize_by(name: name)
      end
    end

    def add_error(line_number, message)
      result.errors << "Fila #{line_number}: #{message}"
    end

    def blank_to_nil(value)
      value.to_s.strip.presence
    end

    def integer_value(value)
      value.to_s.strip.presence&.to_i
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

    def boolean_value(value)
      ActiveModel::Type::Boolean.new.cast(value)
    end
  end
end
