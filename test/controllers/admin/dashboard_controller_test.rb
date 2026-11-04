require "test_helper"

class Admin::DashboardControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  test "should get show" do
    sign_in User.create!(email: "dashboard-admin@example.com", password: "password123", role: "admin")
    get admin_root_url
    assert_response :success
  end
end
