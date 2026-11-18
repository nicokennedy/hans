module DeliveryRoutes
  module Events
    module_function

    def record(route, user, type, stop: nil, reason: nil, **data)
      route.events.create!(user: user, delivery_stop: stop, event_type: type, reason: reason.presence, data: data, created_at: Time.current)
    end
  end
end
