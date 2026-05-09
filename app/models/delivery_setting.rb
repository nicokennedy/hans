class DeliverySetting < ApplicationRecord
  validates :cutoff_hour, presence: true

  def self.current
    first_or_create!(
      cutoff_hour: 14,
      unavailable_weekdays: [0, 2, 4]
    )
  end
end