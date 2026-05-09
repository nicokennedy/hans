require "test_helper"

class Admin::ProductionControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get admin_production_index_url
    assert_response :success
  end
end
