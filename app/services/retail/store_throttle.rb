module Retail
  # Freno simple contra abuso de la tienda pública (bots que llenan carritos o mandan pedidos en
  # serie): cuenta acciones por IP en una ventana de tiempo. Vive en la memoria de cada proceso web,
  # sin servicios externos: alcanza para el volumen de HANS; con varios dynos el límite es por dyno.
  # Junto con el campo trampa del checkout (honeypot) y la idempotencia por token.
  module StoreThrottle
    LIMITS = {
      cart: { max: 120, period: 10.minutes },
      checkout: { max: 20, period: 10.minutes },
      order: { max: 5, period: 30.minutes }
    }.freeze

    STORE = ActiveSupport::Cache::MemoryStore.new(size: 4.megabytes)

    module_function

    # true si la acción todavía está permitida (y la cuenta).
    def allow?(action, ip)
      limit = LIMITS.fetch(action)
      key = "retail-store:#{action}:#{ip}"
      count = STORE.increment(key, 1, expires_in: limit[:period])
      if count.nil?
        STORE.write(key, 1, expires_in: limit[:period], raw: true)
        count = 1
      end
      count <= limit[:max]
    end

    def reset!
      STORE.clear
    end
  end
end
