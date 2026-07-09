require "csv"

module Products
  class CsvExporter
    HEADERS = %w[
      id
      name
      category_name
      internal_category
      public_category
      price
      cost
      active
      position
      unit
      description
    ].freeze

    DEFAULT_PATH = Rails.root.join("db/products.csv")

    def initialize(path: DEFAULT_PATH)
      @path = Pathname.new(path.to_s)
    end

    def call
      CSV.open(path, "w", write_headers: true, headers: HEADERS) do |csv|
        Product.includes(:category).ordered.each do |product|
          csv << [
            product.id,
            product.name,
            product.category&.name,
            product.internal_category,
            product.public_category,
            money_value(product.price_cents),
            money_value(product.cost_cents),
            product.active,
            product.position,
            product.unit,
            product.description
          ]
        end
      end

      path
    end

    private

    attr_reader :path

    def money_value(cents)
      return nil if cents.nil?

      cents = cents.to_i
      return cents / 100 if (cents % 100).zero?

      format("%.2f", cents / 100.0)
    end
  end
end
