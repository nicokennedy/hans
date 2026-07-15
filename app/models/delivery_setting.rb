class DeliverySetting < ApplicationRecord
  validates :cutoff_hour, presence: true

  def self.current
    first_or_create!(
      cutoff_hour: 0,
      unavailable_weekdays: DeliveryDateValidator.unavailable_weekdays
    )
  end
end
