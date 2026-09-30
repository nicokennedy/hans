module Stock
  # "Registrar producción": las chicas cargan cuánto hicieron y el sistema
  # suma al físico, dejando el movimiento en el historial. Nunca resta nada
  # de ningún ingrediente/componente automáticamente — eso está fuera de
  # alcance a propósito (ver punto 21 del pedido original).
  class RegisterProduction
    class InvalidQuantityError < StandardError; end

    def self.call(stock_item:, quantity:, user:, note: nil)
      new(stock_item, quantity, user, note).call
    end

    def initialize(stock_item, quantity, user, note)
      @stock_item = stock_item
      @quantity = quantity.to_d
      @user = user
      @note = note
    end

    def call
      raise InvalidQuantityError, "La cantidad producida debe ser mayor a cero" unless quantity.positive?

      stock_item.apply_movement!(movement_type: :production, quantity: quantity, user: user, note: note)
    end

    private

    attr_reader :stock_item, :quantity, :user, :note
  end
end
