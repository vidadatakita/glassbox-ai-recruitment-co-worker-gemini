ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
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
