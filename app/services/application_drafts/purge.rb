module ApplicationDrafts
  # An unsubmitted draft holds a person's details and CV without an application, so it is deleted once
  # the vacancy's portal is closed (Vida 17 Oct 2026: "an unsubmitted draft expires after closing").
  # Submitted drafts are kept: they carry the applicant's test. Run by ApplicationDraftPurgeJob.
  module Purge
    module_function

    # Returns the number deleted.
    def call(now: Time.current)
      deleted = 0
      ApplicationDraft.where(submitted_at: nil).includes(:job).find_each do |draft|
        next if ApplicationWindow.new(draft.job, now:).open?

        draft.cv.purge if draft.cv.attached?
        draft.destroy!
        deleted += 1
      end
      deleted
    end
  end
end
