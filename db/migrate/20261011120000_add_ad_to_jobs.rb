# AI Builder Cup step 02: the job ad itself (until now "approve ad" approved the job, not a text).
# ad_text is what candidates read on the Lamar page; ad_flags is the last discrimination check of
# that text (Briefs::AdCheck): [{ "quote", "reason", "source" => "rule" | "ai" }]. With any flag, HR
# confirms having checked them before approving.
class AddAdToJobs < ActiveRecord::Migration[8.1]
  def change
    add_column :jobs, :ad_text, :text
    add_column :jobs, :ad_flags, :jsonb, null: false, default: []
  end
end
