require "csv"

module Orders
  class CsvExporter
    HEADERS = [
      "Número de pedido",
      "Fecha del pedido",
      "Cliente",
      "Fecha de entrega",
      "Producto",
      "Cantidad",
      "Costo unitario",
      "Precio unitario",
      "Total producto",
      "Total pedido",
      "Pagado",
      "Pendiente"
    ].freeze

    # BOM UTF-8: sin esto, Excel en Windows/Argentina suele interpretar el
    # archivo con otra codificación y corrompe tildes/ñ (Cliente, Producto).
    BOM = "﻿"

    def initialize(orders)
      @orders = orders
    end

    def call
      BOM + CSV.generate(write_headers: true, headers: HEADERS) do |csv|
        orders.each do |order|
          order.order_items.each do |item|
            csv << [
              order.number,
              order.created_at.strftime("%d/%m/%Y"),
              order.customer.name,
              order.delivery_date.strftime("%d/%m/%Y"),
              item.product_name_snapshot,
              item.quantity,
              money(item.unit_cost_cents_snapshot),
              money(item.unit_price_cents_snapshot),
              money(item.line_revenue_cents),
              money(order.total_cents),
              money(order.amount_paid_cents),
              money(order.balance_due_cents)
            ]
          end
        end
      end
    end

    private

    attr_reader :orders

    # Importe plano en pesos con 2 decimales (ej. 12500.50), sin "$" ni
    # separador de miles, para poder operar la columna como número en
    # Excel/Sheets. cents siempre representa valores históricos/snapshot,
    # nunca el precio o costo actual del producto.
    def money(cents)
      format("%.2f", cents.to_i / 100.0)
    end
  end
end
