# Builders for the technical-test tests (D60 slice 2). Every case text is invented.
module TestCaseFactory
  # A real, minimal .xlsx written by caxlsx (no macros), as bytes.
  def xlsx_bytes(rows = [["Kode", "Qty"], ["BRG-01", 10]])
    require "caxlsx"
    package = Axlsx::Package.new
    package.workbook.add_worksheet(name: "Kasus") { |sheet| rows.each { |r| sheet.add_row(r) } }
    package.to_stream.read
  end

  def upload(bytes, name, type = "application/octet-stream")
    Rack::Test::UploadedFile.new(StringIO.new(bytes.b), type, original_filename: name)
  end

  def case_version_params(job, weights: [60, 40], file: upload(xlsx_bytes, "kasus.xlsx"))
    activities = job.activities.to_a
    { instructions: "Periksa lembar stok, temukan selisih, lalu tulis koreksinya.", time_limit_minutes: "35",
      answer_types_submitted: "1", answer_types: %w[xlsx], case_file: file,
      criteria: weights.each_with_index.to_h do |w, i|
        [i.to_s, { activity_id: activities[i % activities.size].id.to_s, name: "Kriteria uji #{i + 1}", weight: w.to_s,
                   anchor_1: "Selisih tidak ditemukan", anchor_3: "Selisih ditemukan sebagian", anchor_5: "Semua selisih ditemukan dan dijelaskan" }]
      end }
  end

  # Uploads and approves a version through the same services as the screen.
  def approved_test_case!(job, consultant: staff_user("consultant"), hr: staff_user("hr_pic"))
    saved = TestCases::SaveVersion.call(job:, actor: consultant, params: case_version_params(job))
    assert saved.ok?, "test case refused: #{saved.errors.inspect}"
    approved = TestCases::Approve.call(test_case: saved.test_case, actor: hr)
    assert approved.ok?, "approval refused: #{approved.errors.inspect}"
    saved.test_case.reload
  end
end
