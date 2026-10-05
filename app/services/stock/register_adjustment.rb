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

      # El conteo físico es lo que QUEDÓ después de las salidas del día. Si hay
      # salidas vencidas todavía sin materializar (la conciliación es "perezosa":
      # corre al abrir el panel), se materializan ANTES de fijar el conteo; si no,
      # se descontarían después sobre un número que ya las incluía. Con esto el
      # conteo deja exactamente la cantidad ingresada y cualquier conciliación
      # posterior es idempotente (delta cero).
      Stock::DispatchReconciler.reconcile_due!

      stock_item.count!(counted_quantity: counted_quantity, user: user, note: note)
    end

    private

    attr_reader :stock_item, :counted_quantity, :user, :note
  end
end
