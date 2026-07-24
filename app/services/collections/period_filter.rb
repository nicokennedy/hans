module Collections
  class PeriodFilter
    VALID_PERIODS = %w[last_7_days this_month last_month custom].freeze

    LABELS = {
      "last_7_days" => "Últimos 7 días",
      "this_month" => "Este mes",
      "last_month" => "Mes anterior",
      "custom" => "Personalizado"
    }.freeze

    attr_reader :period, :from, :to

    def initialize(period: nil, from: nil, to: nil)
      @period = VALID_PERIODS.include?(period) ? period : "this_month"
      @from, @to = resolve(from, to)
    end

    def label
      LABELS[period]
    end

    private

    def resolve(from, to)
      case period
      when "last_7_days"
        [6.days.ago.to_date, Date.current]
      when "last_month"
        month = 1.month.ago.to_date
        [month.beginning_of_month, month.end_of_month]
      when "custom"
        [parse_date(from) || Date.current.beginning_of_month, parse_date(to) || Date.current]
      else
        [Date.current.beginning_of_month, Date.current.end_of_month]
      end
    end

    def parse_date(value)
      return nil if value.blank?

      Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end
  end
end
