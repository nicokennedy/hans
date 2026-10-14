# app/models/order_item.rb
class OrderItem < ApplicationRecord
  belongs_to :order
  belongs_to :product
  # Excepción administrativa explícita: quién autorizó cargar un producto no habilitado para el cliente.
  belongs_to :restriction_override_by, class_name: "User", optional: true

  validates :quantity, numericality: { greater_than: 0 }
  validates :unit_price_cents_snapshot, numericality: { greater_than_or_equal_to: 0 }

  # Las altas de pedido se validan en Order (un solo mensaje por producto); acá se cubren los
  # ítems guardados directamente en un pedido existente (agregar, reemplazar o subir cantidad).
  validate :product_available_to_customer, if: -> { order&.persisted? }

  before_validation :set_snapshots, on: :create
  before_validation :calculate_totals

  # Red de seguridad: Admin::OrdersController edita/agrega/borra order_items
  # directamente (item.save!/create!/destroy!) y recién al final llama
  # order.update!, que es lo que dispara Order#reconcile_stock_dispatch. Si
  # alguna vez un order_item se guarda sin pasar por ahí, esto asegura que
  # igual se reconcilie — Stock::DispatchReconciler es idempotente (delta
  # 0 si ya estaba al día), así que disparar de más nunca hace daño.
  after_save :reconcile_order_stock_dispatch
  after_destroy :reconcile_order_stock_dispatch

  def unit_price_amount
    unit_price_cents_snapshot.to_i / 100
  end

  def unit_price_amount=(value)
    self.unit_price_cents_snapshot = value.to_s.gsub(".", "").gsub(",", "").to_i * 100
  end

  # true si este ítem agrega demanda de un producto que el cliente del pedido no tiene habilitado:
  # ítem nuevo, producto reemplazado o cantidad aumentada. Las ediciones que no agregan ni
  # sustituyen producto (precio, comentario, bajar cantidad) siguen siendo posibles en pedidos
  # históricos. Una excepción administrativa registrada (restriction_override_by) lo permite.
  def adds_unauthorized_product?
    return false if product.nil? || order&.customer.nil? || restriction_override_by_id.present? || restriction_override_by.present?
    return false unless new_record? || product_id_changed? || (quantity_changed? && quantity.to_i > quantity_was.to_i)

    !product.available_to?(order.customer)
  end

  def assign_product(new_product)
    self.product = new_product
    self.product_name_snapshot = new_product.name
    self.category_name_snapshot = new_product.category&.name
    self.unit_cost_cents_snapshot = new_product.cost_cents.to_i
  end

  private

  def product_available_to_customer
    return unless adds_unauthorized_product?

    errors.add(:base, "#{product.name}: este producto no está disponible para este cliente.")
  end

  def set_snapshots
    self.product_name_snapshot ||= product.name
    self.category_name_snapshot ||= product.category&.name
    self.unit_price_cents_snapshot ||= product.price_cents
    self.unit_cost_cents_snapshot ||= product.cost_cents.to_i
  end

  def calculate_totals
    self.line_revenue_cents = quantity.to_i * unit_price_cents_snapshot.to_i
    self.line_cost_cents = quantity.to_i * unit_cost_cents_snapshot.to_i
  end

  def reconcile_order_stock_dispatch
    Stock::DispatchReconciler.call(order)
  end
end