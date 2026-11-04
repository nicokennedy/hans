ENV["RAILS_ENV"] ||= "test"
# En macOS, pg con cifrado GSS se cuelga en los procesos hijos de los tests en paralelo
# ("Rails test worker … (starting)"). Sin GSS (no se usa en local ni en CI) corren normalmente.
ENV["PGGSSENCMODE"] ||= "disable"
require_relative "../config/environment"
require "rails/test_help"
# Con Minitest 5, Object#stub vive en minitest/mock (no se carga solo).
require "minitest/mock"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    include ActiveJob::TestHelper

    # Próximo día habitual de entrega mayorista desde mañana (lunes, miércoles, viernes o
    # sábado). Los tests que crean pedidos "para mañana" fallaban los días en que mañana es
    # martes, jueves o domingo; con esto no dependen del día en que se corren.
    def next_delivery_date(from: Date.tomorrow)
      date = from
      date += 1 while DeliveryDateValidator.unavailable_weekdays.include?(date.wday)
      date
    end
  end
end
