class DeliveryIncome < ApplicationRecord
  KINDS = {
    "additional_collection" => "Cobro adicional",
    "hans_cash" => "Dinero recibido de HANS",
    "other" => "Otro ingreso"
  }.freeze

  belongs_to :delivery_route, inverse_of: :incomes
  belongs_to :created_by, class_name: "User"
  belongs_to :voided_by, class_name: "User", optional: true
  belongs_to :replaces, class_name: "DeliveryIncome", optional: true
  has_one_attached :evidence

  validates :kind, inclusion: { in: KINDS.keys }
  validates :description, presence: true, length: { maximum: 500 }
  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :void_reason, presence: true, if: :voided?

  def voided?
    voided_at.present?
  end

  def kind_label
    KINDS.fetch(kind)
  end
end
