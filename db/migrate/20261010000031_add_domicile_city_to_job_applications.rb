# D54 (GlassBox Team, 2026-10-10 18:3x): optional "Kota domisili" on the Lamar data step. City or kabupaten
# only, never an address: at most 60 characters and no digits (a street number, RT/RW or postcode
# would need digits; the form also refuses "Jl."/RT/RW shapes with a Bahasa message, see
# ScreeningReport::DomicileCity). Shown in the report under the contact rule; never sent to the AI,
# never scored. Additive: one nullable column and one CHECK no existing row can break (all NULL).
class AddDomicileCityToJobApplications < ActiveRecord::Migration[8.1]
  def change
    add_column :job_applications, :domicile_city, :string, limit: 60
    add_check_constraint :job_applications,
                         "domicile_city IS NULL OR (length(btrim(domicile_city)) BETWEEN 1 AND 60 AND domicile_city !~ '[0-9]')",
                         name: "job_applications_domicile_city_shape"
  end
end
