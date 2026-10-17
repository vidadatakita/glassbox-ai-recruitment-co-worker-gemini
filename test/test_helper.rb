ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# Draw the routes NOW, with the test environment's settings. Rails 8 draws them lazily on first use,
# and config/routes.rb cuts routes when DEMO_MODE=1: a test that seeds under DEMO_MODE=1 (the demo
# seed and page-tour tests) would otherwise draw the cut set for its whole worker, and every later test
# in that worker would fail on a missing route helper, depending on test order (17 Oct 2026).
# Tests that need the cut set reload the routes themselves (test/config/demo_routes_test.rb).
Rails.application.reload_routes_unless_loaded
require_relative "test_helpers/session_test_helper"

Dir[Rails.root.join("test/support/**/*.rb")].each { |f| require f }

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
    include ScoringFactory
    include PortalFactory
    include BriefFactory
  end
end

# The one client company tests use (jobs.client_company_id is NOT NULL; TENANCY=single allows one).
module TestCompany
  def default_company
    ClientCompany.first || ClientCompany.create!(name: "PT Uji Sejahtera", address: "Jl. Contoh 1", city: "Bekasi",
                                                 contact_email: "hr@uji.example")
  end
end
ActiveSupport::TestCase.include(TestCompany)
ActionDispatch::IntegrationTest.include(TestCompany)
