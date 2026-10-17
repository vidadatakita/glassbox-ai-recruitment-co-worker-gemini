module Staff
  # Feature 08, "Screening report" (D61, D62): the summary list, the per-candidate detail
  # ("Candidate detail") and the xlsx. Read-only; the writes are in
  # ScreeningReportActionsController. Roles as for the candidate detail (BP §1.2; D40 owner yes;
  # admin no, test engine F13). What each role sees (names, contacts) is
  # ScreeningReport::Visibility's rule, applied by the board and the views, never here.
  class ScreeningReportsController < BaseController
    XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

    before_action -> { require_role!(:hr_admin, :hr_manager) }
    before_action :load_board

    def index; end

    def show
      @row = @board.row_for(params[:application_id]) or raise ActiveRecord::RecordNotFound
    end

    def export
      package = ScreeningReport::BuildWorkbook.call(@board)
      blind = @board.visibility.blind? ? "-anonim" : ""
      send_data package.to_stream.read, type: XLSX, disposition: "attachment",
                                        filename: "screening-report-#{@board.job.id}#{blind}-#{@board.now.strftime('%Y%m%d-%H%M')}.xlsx"
    end

    private

    def load_board
      @board = ScreeningReportBoard.new(org_jobs.find(params[:job_id]), current_user)
      raise ActiveRecord::RecordNotFound unless @board.applicable?
    end
  end
end
