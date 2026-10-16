# One approved technical test (feature 07, D60 slice 2) for each D49 demo job whose package runs S2.
#
# EVERYTHING HERE IS INVENTED DEMO CONTENT for the fictional "PT Contoh Maju Bersama": the case
# workbooks, their figures, the deliberate errors and the rubrics. No real client data. The jobs are
# operations roles, so each case is an operations sheet with planted mistakes the candidate must find
# and correct (D60's own example is an accounting journal; adapted per role).
#
# Written through the same services as the screen (TestCases::SaveVersion as the demo consultant,
# TestCases::Approve as the HR PIC), so a seed that breaks a rule fails loudly. Idempotent: a job
# that already has an approved version is left alone; nothing is written twice.
require "caxlsx"

module DemoTestCases
  # A file-like object for the services (they read the upload the way the form sends it).
  class SeedUpload < StringIO
    attr_reader :original_filename

    def initialize(bytes, filename)
      super(bytes)
      @original_filename = filename
    end
  end

  CONSULTANT_EMAIL = "consultant@glassbox.example".freeze

  # title => [file name, instructions, data sheet rows (first row = header), [[activity index, criterion, weight, a1, a3, a5], ...]]
  CASES = {
    "Operator Produksi" => [
      "laporan-produksi-shift.xlsx",
      "Lembar Data berisi laporan produksi satu shift lini pengemasan. Ada 3 kesalahan: jumlah total, persentase reject, dan satu jam henti mesin yang tercatat dua kali. Tandai baris yang salah, tulis angka yang benar di lembar Jawaban, dan jelaskan satu kalimat penyebabnya.",
      [["Jam", "Target (pcs)", "Hasil baik (pcs)", "Reject (pcs)", "Henti mesin (menit)"],
       ["07.00-08.00", 1200, 1180, 20, 0], ["08.00-09.00", 1200, 1090, 35, 10], ["09.00-10.00", 1200, 1150, 25, 10],
       ["10.00-11.00", 1200, 1195, 15, 0], ["Total", 4800, 4715, 95, 20], ["Reject (%)", nil, nil, "1,2%", nil]],
      [[3, "Ketelitian mencatat hasil produksi", 60, "Tidak menemukan kesalahan total", "Menemukan satu atau dua kesalahan", "Menemukan ketiga kesalahan dengan angka benar"],
       [2, "Memahami mutu dan reject", 40, "Persentase reject tidak dikoreksi", "Persentase dikoreksi tanpa penjelasan", "Persentase dikoreksi dan penyebab dijelaskan"]]
    ],
    "Team Leader Gudang" => [
      "rekonsiliasi-stok-gudang.xlsx",
      "Lembar Data berisi kartu stok dan hasil hitung fisik 8 barang. Ada 4 selisih yang ditanam: satu salah hitung saldo, satu penerimaan tercatat dua kali, satu barang salah kode, dan satu selisih fisik nyata. Untuk setiap selisih, tulis penyebab yang paling mungkin dan koreksi jurnal stoknya di lembar Jawaban.",
      [["Kode", "Barang", "Saldo awal", "Masuk", "Keluar", "Saldo sistem", "Hitung fisik"],
       ["BRG-101", "Karton 40x30", 500, 200, 350, 350, 350], ["BRG-102", "Lakban cokelat", 120, 60, 90, 100, 90],
       ["BRG-103", "Palet kayu", 40, 20, 15, 45, 45], ["BRG-104", "Stretch film", 75, 50, 40, 135, 85],
       ["BRG-105", "Label rak", 300, 0, 120, 180, 180], ["BRG-106", "Plastik bubble", 60, 30, 30, 60, 54],
       ["BRG-170", "Karton 50x40", 210, 100, 160, 150, 150], ["BRG-108", "Sarung tangan", 200, 100, 150, 150, 150]],
      [[1, "Menemukan dan menjelaskan selisih stok", 50, "Selisih tidak ditemukan", "Dua atau tiga selisih ditemukan", "Keempat selisih ditemukan dengan penyebab yang masuk akal"],
       [2, "Koreksi pencatatan sesuai prosedur", 30, "Koreksi tidak ditulis", "Koreksi ditulis tanpa dokumen pendukung", "Koreksi ditulis lengkap dengan dokumen yang diperlukan"],
       [5, "Tindak lanjut ke regu", 20, "Tidak ada tindak lanjut", "Tindak lanjut umum", "Tindak lanjut spesifik untuk mencegah selisih berulang"]]
    ],
    "Supervisor Produksi" => [
      "rencana-vs-realisasi-produksi.xlsx",
      "Lembar Data membandingkan rencana dan realisasi produksi satu minggu untuk dua lini. Hitung ulang pencapaian per hari, temukan 3 angka yang salah, lalu tulis dua tindakan untuk hari dengan pencapaian terendah di lembar Jawaban.",
      [["Hari", "Lini", "Rencana (pcs)", "Realisasi (pcs)", "Pencapaian"],
       ["Senin", "A", 5000, 4800, "96%"], ["Senin", "B", 4000, 3200, "90%"], ["Selasa", "A", 5000, 5100, "102%"],
       ["Selasa", "B", 4000, 3900, "98%"], ["Rabu", "A", 5000, 4100, "92%"], ["Rabu", "B", 4000, 3950, "99%"]],
      [[0, "Membaca data rencana dan realisasi", 50, "Pencapaian tidak dihitung ulang", "Sebagian angka salah ditemukan", "Ketiga angka salah ditemukan dan dihitung benar"],
       [1, "Tindakan perbaikan yang tepat", 50, "Tindakan tidak terkait data", "Tindakan umum", "Dua tindakan spesifik pada penyebab di lini terkait"]]
    ],
    "Manager HR" => [
      "rekap-lembur-dan-turnover.xlsx",
      "Lembar Data berisi rekap jam lembur dan jumlah karyawan keluar per departemen selama satu kuartal. Ada 3 kesalahan rumus (total, rata-rata, dan tingkat turnover). Perbaiki angkanya di lembar Jawaban dan tulis satu rekomendasi untuk departemen dengan risiko tertinggi.",
      [["Departemen", "Karyawan rata-rata", "Keluar", "Turnover", "Jam lembur"],
       ["Produksi", 180, 18, "10%", 2400], ["Gudang", 60, 9, "12%", 900], ["Logistik", 40, 2, "5%", 300],
       ["Administrasi", 20, 1, "5%", 60], ["Total", 300, 30, "8%", 3560]],
      [[0, "Ketepatan analisis data SDM", 60, "Kesalahan tidak ditemukan", "Satu atau dua kesalahan diperbaiki", "Ketiga kesalahan diperbaiki dengan rumus benar"],
       [1, "Rekomendasi berbasis data", 40, "Rekomendasi tidak terkait data", "Rekomendasi umum", "Rekomendasi spesifik untuk departemen berisiko tertinggi"]]
    ],
    "General Manager Operasional" => [
      "kpi-operasional-bulanan.xlsx",
      "Lembar Data berisi KPI operasional tiga bulan (produksi, pengiriman tepat waktu, biaya per unit). Dua angka tidak konsisten antar kolom dan satu tren digambarkan terbalik. Temukan ketiganya dan tulis tiga prioritas bulan depan di lembar Jawaban.",
      [["Bulan", "Produksi (ribu pcs)", "Tepat waktu", "Biaya per unit (Rp)", "Catatan"],
       ["Juli", 410, "96%", 1850, "Stabil"], ["Agustus", 395, "93%", 1920, "Biaya turun"], ["September", 430, "97%", 1880, "Produksi turun"]],
      [[0, "Membaca KPI lintas fungsi", 50, "Inkonsistensi tidak ditemukan", "Sebagian ditemukan", "Ketiga inkonsistensi ditemukan dan dijelaskan"],
       [1, "Menetapkan prioritas", 50, "Prioritas tidak terkait data", "Prioritas umum", "Tiga prioritas terukur yang menjawab temuan"]]
    ],
    "Direktur Operasional" => [
      "anggaran-vs-realisasi-opex.xlsx",
      "Lembar Data berisi anggaran dan realisasi biaya operasional satu semester. Ada 2 salah jumlah dan 1 pos yang dimasukkan ke kategori yang salah. Koreksi angkanya dan tulis ringkasan satu paragraf untuk direksi di lembar Jawaban.",
      [["Pos biaya", "Kategori", "Anggaran (Rp juta)", "Realisasi (Rp juta)", "Selisih"],
       ["Listrik pabrik", "Utilitas", 1200, 1310, 110], ["Sewa forklift", "Utilitas", 300, 280, -20],
       ["Perawatan mesin", "Pemeliharaan", 650, 720, 60], ["Transportasi", "Logistik", 900, 870, -30],
       ["Total", nil, 3050, 3180, 120]],
      [[0, "Ketajaman analisis anggaran", 50, "Kesalahan tidak ditemukan", "Sebagian kesalahan diperbaiki", "Seluruh kesalahan diperbaiki dengan benar"],
       [1, "Komunikasi ke direksi", 50, "Ringkasan tidak jelas", "Ringkasan benar tetapi panjang", "Ringkasan singkat, berangka, dan menyebut keputusan yang diperlukan"]]
    ]
  }.freeze

  module_function

  # Ensures one approved version for the job, when its package runs S2. Returns the version or nil.
  def ensure!(job, hr:)
    return unless TestCases::Requirement.applies?(job)

    current = TechnicalTestCase.current_for(job)
    return current if current

    data = CASES.fetch(job.title) { raise "no demo test case for #{job.title}" }
    save = TestCases::SaveVersion.call(job:, actor: consultant, params: params_for(job, data))
    raise "demo test case #{job.title} refused: #{save.errors.join(' | ')}" unless save.ok?

    approve = TestCases::Approve.call(test_case: save.test_case, actor: hr)
    raise "demo test case #{job.title} not approved: #{approve.errors.join(' | ')}" unless approve.ok?

    save.test_case.reload
  end

  def consultant
    User.find_by(email_address: CONSULTANT_EMAIL) || User.where(role: "consultant").order(:id).first ||
      User.create!(email_address: CONSULTANT_EMAIL, name: "Rangga Saputra", role: "consultant", password: SecureRandom.base58(24))
  end

  def params_for(job, (filename, instructions, rows, criteria))
    activities = job.activities.to_a
    { instructions:, time_limit_minutes: "35", answer_types_submitted: "1", answer_types: %w[xlsx],
      case_file: SeedUpload.new(workbook(instructions, rows), filename),
      criteria: criteria.each_with_index.to_h do |(index, name, weight, a1, a3, a5), i|
        [i.to_s, { activity_id: activities.fetch(index).id.to_s, name:, weight: weight.to_s, anchor_1: a1, anchor_3: a3, anchor_5: a5 }]
      end }
  end

  # Three sheets: Petunjuk, Data (with the planted errors), Jawaban (empty, for the candidate).
  def workbook(instructions, rows)
    package = Axlsx::Package.new
    book = package.workbook
    bold = book.styles.add_style(b: true)
    book.add_worksheet(name: "Petunjuk") do |sheet|
      sheet.add_row(["Studi kasus (contoh, data fiktif)"], style: bold)
      sheet.add_row([instructions])
    end
    book.add_worksheet(name: "Data") do |sheet|
      sheet.add_row(rows.first, style: bold)
      rows.drop(1).each { |row| sheet.add_row(row) }
    end
    book.add_worksheet(name: "Jawaban") { |sheet| sheet.add_row(["Baris / pos", "Angka yang benar", "Penjelasan"], style: bold) }
    package.to_stream.read
  end
end
