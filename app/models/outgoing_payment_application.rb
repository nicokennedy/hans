class OutgoingPaymentApplication < ApplicationRecord
  KINDS = %w[distribution advance].freeze

  belongs_to :outgoing_payment
  belongs_to :obligation
  belongs_to :user, optional: true

  validates :amount_cents, numericality: { only_integer: true, greater_than: 0 }
  validates :kind, inclusion: { in: KINDS }
  validates :void_reason, presence: true, if: :voided?

  scope :active, -> { where(voided_at: nil) }

  def voided?
    voided_at.present?
  end

  def advance?
    kind == "advance"
  end
end
