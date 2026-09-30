module Stock
  # "Contar / corregir stock": la chica cuenta el freezer y carga lo que
  # ve. El sistema NUNCA pisa el número en silencio — calcula la diferencia
  # contra lo que el sistema creía y la deja como un movimiento de ajuste
  # explícito (ver StockItem#count!).
  class RegisterAdjustment
    class InvalidQuantityError < StandardError; end

    def self.call(stock_item:, counted_quantity:, user:, note: nil)
      new(stock_item, counted_quantity, user, note).call
    end

    def initialize(stock_item, counted_quantity, user, note)
      @stock_item = stock_item
      @counted_quantity = counted_quantity.to_d
      @user = user
      @note = note
    end

    def call
      raise InvalidQuantityError, "El conteo no puede ser negativo" if counted_quantity.negative?

      stock_item.count!(counted_quantity: counted_quantity, user: user, note: note)
    end

    private

    attr_reader :stock_item, :counted_quantity, :user, :note
  end
end
