require "bigdecimal"

module Stock
  # Agrega el consumo de StockItem de un conjunto de OrderItem — reutiliza
  # Stock::ProductConsumption memoizado por producto (si dos líneas del
  # mismo pedido, o líneas de pedidos distintos, comparten producto, no se
  # recalcula el recorrido de receta dos veces). Es la pieza que hace que
  # "Mini Brownie" y "Cuadrado Brownie" sumen al MISMO pool: ambos
  # resuelven al mismo StockItem, y acá se están agregando en el mismo Hash.
  class Demand
    def self.for_order_items(order_items)
      new.for_order_items(order_items)
    end

    def initialize
      @memo = {}
    end

    def for_order_items(order_items)
      result = Hash.new(BigDecimal(0))

      order_items.each do |order_item|
        per_unit_map = consumption_for(order_item.product)
        per_unit_map.each do |stock_item, per_unit|
          result[stock_item] += per_unit * order_item.quantity.to_d
        end
      end

      result
    end

    private

    def consumption_for(product)
      @memo[product.id] ||= Stock::ProductConsumption.call(product)
    end
  end
end
