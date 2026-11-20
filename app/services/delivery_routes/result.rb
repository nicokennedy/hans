module DeliveryRoutes
  Result = Struct.new(:route, :errors, :already, keyword_init: true) do
    def ok?
      errors.blank?
    end
  end
end
