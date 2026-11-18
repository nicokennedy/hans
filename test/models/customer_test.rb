require "test_helper"

class CustomerTest < ActiveSupport::TestCase
  # test "the truth" do
  #   assert true
  # end

  test "google maps url uses the delivery address and is nil without one" do
    assert_nil Customer.new(name: "Sin dirección").google_maps_url

    customer = Customer.new(name: "Café", address: "Av. Colón 2345")
    assert_equal "Av. Colón 2345, Argentina", customer.maps_query
    assert_equal "https://www.google.com/maps/search/?api=1&query=Av.%20Col%C3%B3n%202345%2C%20Argentina", customer.google_maps_url
  end

  test "google maps query adds city, province and postal code but not the unit or instructions" do
    customer = Customer.new(name: "Café", address: "Av. Colón 2345", address_unit: "Local 3", city: "Mar del Plata",
                            province: "Buenos Aires", postal_code: "7600", delivery_instructions: "Timbre verde")

    assert_equal "Av. Colón 2345, Mar del Plata, Buenos Aires, 7600, Argentina", customer.maps_query
  end
end
