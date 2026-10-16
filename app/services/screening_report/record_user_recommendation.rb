module ScreeningReport
  # "Rekomendasi User" (D62 h6, T1): the HR PIC records the hiring manager's pick, naming the
  # manager. Information only; never a Decision (D64 C1). The database trigger
  # enforce_user_recommendation_actor holds the HR PIC rule too.
  class RecordUserRecommendation
    class Refused < StandardError; end

    def self.call(**) = new(**).call

    def initialize(application:, user:, user_name:, pick:, note: nil)
      @application = application
      @user = user
      @user_name = user_name.to_s.strip
      @pick = pick.to_s
      @note = note.to_s.strip.presence
    end

    def call
      refuse("Only the HR owner records the hiring manager's pick.") unless @user.role == "hr_pic"
      refuse("Write the name of the hiring manager who made the pick.") if @user_name.empty?
      refuse("Choose Continue or Do not continue.") unless UserRecommendation::PICKS.key?(@pick)

      UserRecommendation.create!(job_application: @application, user_name: @user_name[0, 120], pick: @pick,
                                 note: @note, entered_by: @user, created_at: Time.current)
    end

    private

    def refuse(message) = raise(Refused, message)
  end
end
