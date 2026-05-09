class CreateBlockedDates < ActiveRecord::Migration[7.1]
  def change
    create_table :blocked_dates do |t|
      t.date :date
      t.string :reason
      t.boolean :active

      t.timestamps
    end
  end
end
