# Fixtures that need a later-stage participation (S3, S4, S5, RC) call enter_stage_by_choice!.
#
# Merge of 2026-10-12 (stash of the 2026-10-10 session over the team's main 79eb244): the live D63 design
# is the AI Builder Cup one (app/services/progression/*), which has no database rule that a later
# stage needs a person's Lanjut first. The 10-10 version of this helper walked the candidate through
# that withheld implementation (ProgressionChoices::Record); it is in the stash, not in the tree.
# Until the strict entry rule is ported onto the Cup design, a later-stage participation is created
# directly, exactly as these fixtures did before feature 11. If the strict rule is ported, change
# THIS method to go through Progression::Choose and every caller follows.
module ProgressionFactory
  def enter_stage_by_choice!(application, stage, attendance: "pending")
    Participation.create!(job_application: application, stage:, attendance:)
  end
end

ActiveSupport::TestCase.include(ProgressionFactory)
ActionDispatch::IntegrationTest.include(ProgressionFactory)
