# The client company (tenant). With TENANCY=single the database holds exactly one
# (trigger client_companies_single_tenant, ONP-1). Plan 2 adds tenant scoping of every query.
class ClientCompany < ApplicationRecord
  has_many :jobs, dependent: :restrict_with_exception
  has_many :users, dependent: :restrict_with_exception

  validates :name, :address, :city, :contact_email, presence: true
end
