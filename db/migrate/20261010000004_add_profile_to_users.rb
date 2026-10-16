# Roles from blueprint §1.2 (minimal Plan 2). client_company_id is null for DataKita staff.
class AddProfileToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :name, :string, null: false, default: ""
    add_column :users, :role, :string, null: false, default: "hr_pic"
    add_reference :users, :client_company, foreign_key: true
    add_check_constraint :users, "role IN ('owner','hr_pic','consultant','reviewer','admin')", name: "users_role"
  end
end
