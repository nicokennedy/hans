# app/models/order.rb
class Order < ApplicationRecord
  belongs_to :customer
  has_many :order_items, dependent: :destroy
  has_many :order_events, dependent: :destroy

  enum :status, {
    received: "received",
    confirmed: "confirmed",
    in_production: "in_production",
    ready: "ready",
    delivered: "delivered",
    canceled: "canceled",
    needs_review: "needs_review"
  }, default: "received"

  enum :payment_status, {
    pending: "pending",
    partial: "partial",
    paid: "paid"
  }, default: "pending"

  enum :payment_method_selected, {
    cash_on_delivery: "cash_on_delivery",
    cash_later: "cash_later",
    bank_transfer: "bank_transfer"
  }

  validates :delivery_date, presence: true
  validates :status, :payment_status, presence: true
  validate :delivery_date_must_be_available, on: :create

  before_validation :set_defaults
  before_save :recalculate_total

  private

  def set_defaults
    self.status ||= "received"
    self.payment_status ||= "pending"
    self.number ||= "HANS-#{Time.current.strftime('%Y%m%d')}-#{SecureRandom.hex(3).upcase}"
    self.total_cents ||= 0
    self.amount_paid_cents ||= 0
    self.created_by_admin = false if created_by_admin.nil?
  end

  def recalculate_total
    self.total_cents = order_items.sum { |item| item.line_revenue_cents.to_i }
  end

  def delivery_date_must_be_available
    return if delivery_date.blank?

    reason = DeliveryDateValidator.reason(delivery_date)
    errors.add(:delivery_date, reason) if reason.present?
  end
end